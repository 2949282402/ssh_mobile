import 'dart:async';

import 'realtime_media_endpoint.dart';
import 'realtime_media_error.dart';
import 'realtime_media_state.dart';
import 'realtime_media_stats.dart';
import 'remote_video_surface.dart';
import 'screen_capture_source.dart';

/// Narrow platform bridge. Implementations own native media resources.
abstract interface class RealtimeMediaBackend {
  Future<RealtimeMediaEndpointId> start(RealtimeMediaEndpointIdentity identity);

  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  });

  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  /// Reads a low-frequency, payload-free snapshot for one active endpoint.
  ///
  /// Statistics are observational: an unavailable snapshot does not change a
  /// capture or renderer lifecycle that may still be healthy.
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });
}

/// Owns endpoint leases for one `(realtimeId, peerId, generation)` binding.
final class RealtimeMediaSessionController {
  RealtimeMediaSessionController({
    required this.backend,
    required String realtimeId,
    required String peerId,
    required this.generation,
  }) : realtimeId = _validateRealtimeId(realtimeId),
       peerId = _validatePeerId(peerId) {
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
  }

  final RealtimeMediaBackend backend;
  final String realtimeId;
  final String peerId;
  final int generation;
  final Map<RealtimeMediaEndpointId, RealtimeMediaEndpoint> _endpoints =
      <RealtimeMediaEndpointId, RealtimeMediaEndpoint>{};
  final Map<RealtimeMediaEndpointId, Future<void>> _endpointReleases =
      <RealtimeMediaEndpointId, Future<void>>{};
  final Set<RealtimeMediaEndpointId> _pendingAttachments =
      <RealtimeMediaEndpointId>{};

  Future<void>? _terminalRelease;
  Completer<void>? _pendingStartsSettled;
  int _pendingStartCount = 0;
  RealtimeMediaException? _lateStartCleanupFailure;

  RealtimeMediaSessionState state = RealtimeMediaSessionState.idle;

  /// Acquires one native endpoint lease for the supplied direction.
  Future<RealtimeMediaEndpoint> start(RealtimeMediaDirection direction) async {
    _ensureSessionCanStart();
    state = RealtimeMediaSessionState.starting;
    _beginStart();
    final identity = _identity(direction);
    try {
      final endpointId = await backend.start(identity);
      if (_terminalRelease != null ||
          state == RealtimeMediaSessionState.stopping ||
          state == RealtimeMediaSessionState.released) {
        await _releaseEndpointAcquiredDuringStop(endpointId, identity);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.sessionReleased,
          'The media session controller is stopping or has been released.',
        );
      }
      if (state == RealtimeMediaSessionState.failed) {
        await _releaseEndpointAcquiredDuringStop(endpointId, identity);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.failedState,
          'The media session controller is failed.',
        );
      }
      if (_endpoints.containsKey(endpointId)) {
        state = RealtimeMediaSessionState.failed;
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.backendFailure,
          'Native bridge returned a duplicate endpoint ID.',
        );
      }
      final endpoint = RealtimeMediaEndpoint.lease(
        id: endpointId,
        identity: identity,
      );
      _endpoints[endpointId] = endpoint;
      return endpoint;
    } on RealtimeMediaException {
      if (_terminalRelease == null &&
          state != RealtimeMediaSessionState.stopping &&
          state != RealtimeMediaSessionState.released) {
        state = RealtimeMediaSessionState.failed;
      }
      rethrow;
    } catch (_) {
      if (_terminalRelease == null) {
        state = RealtimeMediaSessionState.failed;
      }
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint acquisition failed.',
      );
    } finally {
      _finishStart();
    }
  }

  /// Associates a send endpoint with an opaque platform source descriptor.
  Future<void> attachCaptureSource(
    RealtimeMediaEndpoint endpoint,
    ScreenCaptureSource source,
  ) async {
    _ensureEndpoint(endpoint, expectedDirection: RealtimeMediaDirection.send);
    if (endpoint.isAttached) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one attached source or surface.',
      );
    }
    if (!_pendingAttachments.add(endpoint.id)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one pending source or surface attachment.',
      );
    }
    try {
      await backend.attachCaptureSource(
        endpointId: endpoint.id,
        identity: endpoint.identity,
        source: source,
      );
      if (!_canCommitAttachment(endpoint)) {
        await _cleanupLateAttachment(
          endpointId: endpoint.id,
          identity: endpoint.identity,
          releaseEndpoint: !_isLiveEndpoint(endpoint),
        );
        throw _attachmentCommitFailure(endpoint);
      }
      endpoint.source = source;
      endpoint.state = RealtimeMediaEndpointState.attached;
    } on RealtimeMediaException {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      rethrow;
    } catch (_) {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native source attachment failed.',
      );
    } finally {
      _pendingAttachments.remove(endpoint.id);
    }
  }

  /// Associates a receive endpoint with an opaque renderer capability.
  Future<RemoteVideoSurface> attachRemoteVideoSurface(
    RealtimeMediaEndpoint endpoint,
  ) async {
    _ensureEndpoint(
      endpoint,
      expectedDirection: RealtimeMediaDirection.receive,
    );
    if (endpoint.isAttached) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one attached source or surface.',
      );
    }
    if (!_pendingAttachments.add(endpoint.id)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one pending source or surface attachment.',
      );
    }
    RemoteVideoSurface? surface;
    try {
      surface = await backend.attachRemoteVideoSurface(
        endpointId: endpoint.id,
        identity: endpoint.identity,
      );
      if (!_canCommitAttachment(endpoint) ||
          surface.endpointId != endpoint.id ||
          !surface.identity.matches(endpoint.identity)) {
        await _cleanupLateAttachment(
          endpointId: endpoint.id,
          identity: endpoint.identity,
          surface: surface,
          releaseEndpoint: !_isLiveEndpoint(endpoint),
        );
        if (!_canCommitAttachment(endpoint)) {
          throw _attachmentCommitFailure(endpoint);
        }
        // A malformed native capability may already have allocated a
        // renderer. Best-effort detach it before failing closed; the returned
        // opaque capability is also marked released so it cannot be reused by
        // a caller that retained the bad result.
        _markFailed(endpoint);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.backendFailure,
          'Native bridge returned a surface for another endpoint generation.',
        );
      }
      endpoint.surface = surface;
      endpoint.state = RealtimeMediaEndpointState.attached;
      return surface;
    } on RealtimeMediaException {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      rethrow;
    } catch (_) {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native surface attachment failed.',
      );
    } finally {
      _pendingAttachments.remove(endpoint.id);
    }
  }

  /// Detaches a currently attached source or surface without ending the lease.
  Future<void> detach(RealtimeMediaEndpoint endpoint) async {
    _ensureEndpoint(endpoint);
    if (!endpoint.isAttached) return;
    try {
      await backend.detach(
        endpointId: endpoint.id,
        identity: endpoint.identity,
      );
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      endpoint.source = null;
      endpoint.surface?.release();
      endpoint.surface = null;
      endpoint.state = RealtimeMediaEndpointState.detached;
    } on RealtimeMediaException {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      rethrow;
    } catch (_) {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint detach failed.',
      );
    }
  }

  /// Obtains low-frequency counters without exposing media payloads.
  Future<RealtimeMediaStats> stats(RealtimeMediaEndpoint endpoint) async {
    _ensureEndpoint(endpoint);
    try {
      return await backend.readStats(
        endpointId: endpoint.id,
        identity: endpoint.identity,
      );
    } catch (_) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint statistics are unavailable.',
      );
    }
  }

  /// Releases an endpoint lease; repeating a completed release is safe.
  Future<void> release([RealtimeMediaEndpoint? endpoint]) {
    if (endpoint != null) {
      return _releaseSingleEndpoint(endpoint);
    }

    return _releaseController();
  }

  Future<void> _releaseSingleEndpoint(RealtimeMediaEndpoint endpoint) async {
    if (endpoint.state == RealtimeMediaEndpointState.released) return;
    final terminalRelease = _terminalRelease;
    if (terminalRelease != null) {
      await terminalRelease;
      return;
    }
    _ensureEndpointIdentity(endpoint);
    await _releaseEndpoint(endpoint);
    if (_terminalRelease == null &&
        state != RealtimeMediaSessionState.released) {
      state = RealtimeMediaSessionState.ready;
    }
  }

  Future<void> _releaseController() {
    final terminalRelease = _terminalRelease;
    if (terminalRelease != null) return terminalRelease;
    if (state == RealtimeMediaSessionState.released) {
      return Future<void>.value();
    }

    final completion = Completer<void>();
    _terminalRelease = completion.future;
    state = RealtimeMediaSessionState.stopping;
    unawaited(_releaseAllEndpoints(completion));
    return completion.future;
  }

  Future<void> _releaseAllEndpoints(Completer<void> completion) async {
    RealtimeMediaException? firstFailure;
    try {
      await _waitForPendingStarts();
      firstFailure = _lateStartCleanupFailure;
      for (final lease in _endpoints.values.toList()) {
        try {
          await _releaseEndpoint(lease);
        } on RealtimeMediaException catch (error) {
          firstFailure ??= error;
        }
      }
    } catch (_) {
      firstFailure ??= const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint cleanup failed.',
      );
    } finally {
      state = RealtimeMediaSessionState.released;
    }
    if (firstFailure != null) {
      completion.completeError(firstFailure);
    } else {
      completion.complete();
    }
  }

  /// Stops this session and releases every endpoint lease it owns.
  ///
  /// Stopping is terminal for this controller's immutable realtime generation.
  /// It is deliberately an idempotent lifecycle alias for a controller-level
  /// [release], while [release] with an endpoint retains the narrower lease
  /// cleanup operation.
  Future<void> stop() => release();

  /// Disposes this controller without taking ownership of its NetworkRuntime.
  ///
  /// This is safe before [start] and is idempotent after [stop].
  Future<void> dispose() => stop();

  Future<void> _releaseEndpoint(RealtimeMediaEndpoint endpoint) {
    if (endpoint.state == RealtimeMediaEndpointState.released) {
      return Future<void>.value();
    }
    final existingRelease = _endpointReleases[endpoint.id];
    if (existingRelease != null) return existingRelease;

    final completion = Completer<void>();
    final operation = completion.future;
    _endpointReleases[endpoint.id] = operation;
    unawaited(_releaseEndpointLease(endpoint, completion));
    return operation;
  }

  Future<void> _releaseEndpointLease(
    RealtimeMediaEndpoint endpoint,
    Completer<void> completion,
  ) async {
    RealtimeMediaException? failure;
    try {
      if (endpoint.isAttached) {
        try {
          await backend.detach(
            endpointId: endpoint.id,
            identity: endpoint.identity,
          );
        } catch (_) {
          failure = const RealtimeMediaException(
            RealtimeMediaErrorCode.backendFailure,
            'Native endpoint detach failed.',
          );
        }
      }
    } catch (_) {
      failure ??= const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint cleanup failed.',
      );
    } finally {
      try {
        await backend.release(
          endpointId: endpoint.id,
          identity: endpoint.identity,
        );
      } catch (_) {
        failure ??= const RealtimeMediaException(
          RealtimeMediaErrorCode.backendFailure,
          'Native endpoint release failed.',
        );
      }
      endpoint.source = null;
      endpoint.surface?.release();
      endpoint.state = RealtimeMediaEndpointState.released;
      _endpoints.remove(endpoint.id);
      _endpointReleases.remove(endpoint.id);
    }
    if (failure != null) {
      completion.completeError(failure);
    } else {
      completion.complete();
    }
  }

  RealtimeMediaEndpointIdentity _identity(RealtimeMediaDirection direction) =>
      RealtimeMediaEndpointIdentity(
        realtimeId: realtimeId,
        peerId: peerId,
        generation: generation,
        direction: direction,
      );

  void _ensureSessionCanStart() {
    if (_terminalRelease != null ||
        state == RealtimeMediaSessionState.stopping ||
        state == RealtimeMediaSessionState.released) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.sessionReleased,
        'The media session controller is stopping or has been released.',
      );
    }
    if (state == RealtimeMediaSessionState.failed) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.failedState,
        'The media session controller is failed.',
      );
    }
  }

  void _ensureEndpoint(
    RealtimeMediaEndpoint endpoint, {
    RealtimeMediaDirection? expectedDirection,
  }) {
    if (endpoint.state == RealtimeMediaEndpointState.released) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.useAfterRelease,
        'The endpoint lease has been released.',
      );
    }
    if (_terminalRelease != null ||
        state == RealtimeMediaSessionState.stopping ||
        state == RealtimeMediaSessionState.released) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.sessionReleased,
        'The media session controller is stopping or has been released.',
      );
    }
    _ensureEndpointIdentity(endpoint);
    if (endpoint.state == RealtimeMediaEndpointState.failed ||
        state == RealtimeMediaSessionState.failed) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.failedState,
        'The endpoint or its session is failed.',
      );
    }
    if (expectedDirection != null &&
        endpoint.identity.direction != expectedDirection) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.invalidDirection,
        'The endpoint direction does not permit this attachment.',
      );
    }
  }

  void _ensureEndpointIdentity(RealtimeMediaEndpoint endpoint) {
    final current = _endpoints[endpoint.id];
    if (!identical(current, endpoint) ||
        endpoint.identity.realtimeId != realtimeId ||
        endpoint.identity.peerId != peerId ||
        endpoint.identity.generation != generation) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'The endpoint belongs to another realtime generation.',
      );
    }
  }

  void _markFailed(RealtimeMediaEndpoint endpoint) {
    endpoint.state = RealtimeMediaEndpointState.failed;
    state = RealtimeMediaSessionState.failed;
  }

  bool _isLiveEndpoint(RealtimeMediaEndpoint endpoint) =>
      identical(_endpoints[endpoint.id], endpoint) &&
      endpoint.state != RealtimeMediaEndpointState.released &&
      _terminalRelease == null &&
      state != RealtimeMediaSessionState.stopping &&
      state != RealtimeMediaSessionState.released;

  bool _canCommitAttachment(RealtimeMediaEndpoint endpoint) =>
      _isLiveEndpoint(endpoint) && !endpoint.isAttached;

  RealtimeMediaException _attachmentCommitFailure(
    RealtimeMediaEndpoint endpoint,
  ) {
    if (_terminalRelease != null ||
        state == RealtimeMediaSessionState.stopping ||
        state == RealtimeMediaSessionState.released) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.sessionReleased,
        'The media session controller is stopping or has been released.',
      );
    }
    if (endpoint.state == RealtimeMediaEndpointState.released ||
        !identical(_endpoints[endpoint.id], endpoint)) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.useAfterRelease,
        'The endpoint lease has been released.',
      );
    }
    if (endpoint.isAttached) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one attached source or surface.',
      );
    }
    if (endpoint.state == RealtimeMediaEndpointState.failed ||
        state == RealtimeMediaSessionState.failed) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.failedState,
        'The endpoint or its session is failed.',
      );
    }
    return const RealtimeMediaException(
      RealtimeMediaErrorCode.staleEndpoint,
      'The endpoint belongs to another realtime generation.',
    );
  }

  Future<void> _cleanupLateAttachment({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RemoteVideoSurface? surface,
    required bool releaseEndpoint,
  }) async {
    try {
      await backend.detach(endpointId: endpointId, identity: identity);
    } catch (_) {
      // Keep the lifecycle error deterministic; controller release retries the
      // endpoint-level cleanup when the lease is still owned.
    }
    surface?.release();
    if (!releaseEndpoint) return;
    try {
      await backend.release(endpointId: endpointId, identity: identity);
    } catch (_) {
      // The terminal release caller owns the primary cleanup result.
    }
  }

  void _beginStart() {
    if (_pendingStartCount == 0) {
      _pendingStartsSettled = Completer<void>();
    }
    _pendingStartCount += 1;
  }

  void _finishStart() {
    _pendingStartCount -= 1;
    if (_pendingStartCount != 0) return;

    _pendingStartsSettled!.complete();
    if (_terminalRelease == null &&
        state == RealtimeMediaSessionState.starting) {
      state = RealtimeMediaSessionState.ready;
    }
  }

  Future<void> _waitForPendingStarts() async {
    while (_pendingStartCount > 0) {
      await _pendingStartsSettled!.future;
    }
  }

  Future<void> _releaseEndpointAcquiredDuringStop(
    RealtimeMediaEndpointId endpointId,
    RealtimeMediaEndpointIdentity identity,
  ) async {
    try {
      await backend.release(endpointId: endpointId, identity: identity);
    } catch (_) {
      const failure = RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint cleanup after a stopped start failed.',
      );
      if (_terminalRelease != null) {
        _lateStartCleanupFailure ??= failure;
      }
      throw failure;
    }
  }
}

String _validateRealtimeId(String value) => _validate(value, 'realtime ID');

String _validatePeerId(String value) => _validate(value, 'peer ID');

String _validate(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw ArgumentError.value(value, name, 'must contain 1 to 128 characters');
  }
  return normalized;
}
