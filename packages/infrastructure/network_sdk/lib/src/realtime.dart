import 'dart:async';
import 'dart:typed_data';

import 'network_models.dart';

/// High-level Realtime session state exposed to Flutter features.
///
/// WebRTC negotiation is native-owned. A feature observes this state instead
/// of driving a peer connection, SDP, ICE, or a socket itself.
enum RealtimeSessionState {
  idle,
  starting,
  negotiating,
  connected,
  restarting,
  stopped,
  failed,
}

/// High-level remote audio state.
enum RealtimeAudioState { unavailable, inactive, active, muted, failed }

/// A decoded or otherwise renderable remote video frame supplied by native.
final class RealtimeVideoFrame {
  RealtimeVideoFrame({required Uint8List bytes, required this.timestamp})
    : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  final DateTime timestamp;
}

/// Events emitted by an App/native adapter into [RealtimeClient].
sealed class RealtimeBackendEvent {
  const RealtimeBackendEvent();
}

/// A backend state event consumed by the SDK session coordinator.
final class RealtimeSessionStateChangedEvent extends RealtimeBackendEvent {
  const RealtimeSessionStateChangedEvent({
    required this.realtimeId,
    required this.peerId,
    required this.state,
    this.error,
  });

  final String realtimeId;
  final String peerId;
  final RealtimeSessionState state;
  final NetworkError? error;
}

/// A backend video event consumed by the SDK session coordinator.
final class RealtimeRemoteVideoFrameEvent extends RealtimeBackendEvent {
  RealtimeRemoteVideoFrameEvent({
    required this.realtimeId,
    required this.peerId,
    required Uint8List bytes,
    required this.timestamp,
  }) : bytes = Uint8List.fromList(bytes);

  final String realtimeId;
  final String peerId;
  final Uint8List bytes;
  final DateTime timestamp;
}

/// A backend audio state event consumed by the SDK session coordinator.
final class RealtimeAudioStateChangedEvent extends RealtimeBackendEvent {
  const RealtimeAudioStateChangedEvent({
    required this.realtimeId,
    required this.peerId,
    required this.state,
  });

  final String realtimeId;
  final String peerId;
  final RealtimeAudioState state;
}

/// The native/runtime-facing backend for the high-level SDK client.
abstract interface class RealtimeSessionBackend {
  Stream<RealtimeBackendEvent> get events;

  Future<SdkResult<void>> start({
    required String realtimeId,
    required String peerId,
  });

  Future<SdkResult<void>> stop({required String realtimeId});

  /// Releases backend subscriptions without taking ownership of App Scope
  /// native resources.
  Future<void> dispose() async {}
}

/// A feature-facing Realtime session.
///
/// PeerConnection, ICE, SDP, signaling, and sockets are deliberately absent.
abstract interface class RealtimeSession {
  String get realtimeId;

  String get peerId;

  RealtimeSessionState get state;

  Stream<RealtimeVideoFrame> get remoteVideo;

  RealtimeAudioState get audioState;

  Future<SdkResult<void>> start();

  Future<SdkResult<void>> stop();
}

/// Factory and lifecycle owner for feature-facing Realtime sessions.
abstract interface class RealtimeClient {
  RealtimeSession createSession({
    required String realtimeId,
    required String peerId,
  });

  Future<void> dispose();
}

/// SDK coordinator that maps one backend event stream to many sessions.
final class RealtimeClientImpl implements RealtimeClient {
  RealtimeClientImpl({required RealtimeSessionBackend backend})
    : _backend = backend {
    _backendSubscription = backend.events.listen(_onBackendEvent);
  }

  final RealtimeSessionBackend _backend;
  final Map<String, _RealtimeSession> _sessions = <String, _RealtimeSession>{};
  late final StreamSubscription<RealtimeBackendEvent> _backendSubscription;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  RealtimeSession createSession({
    required String realtimeId,
    required String peerId,
  }) {
    _ensureUsable();
    _validateRealtimeId(realtimeId);
    if (peerId.trim().isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'Peer ID must not be empty.');
    }
    if (_sessions.containsKey(realtimeId)) {
      throw StateError('Realtime session already exists: $realtimeId');
    }
    final session = _RealtimeSession(
      client: this,
      realtimeId: realtimeId,
      peerId: peerId,
    );
    _sessions[realtimeId] = session;
    return session;
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    if (_disposed) return Future<void>.value();
    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    for (final session in _sessions.values.toList()) {
      await session._dispose();
    }
    _sessions.clear();
    await _backendSubscription.cancel();
    await _backend.dispose();
  }

  void _onBackendEvent(RealtimeBackendEvent event) {
    switch (event) {
      case RealtimeSessionStateChangedEvent(:final realtimeId, :final peerId):
        final session = _sessions[realtimeId];
        if (session == null || session.peerId != peerId) return;
        session._applyState(event.state, event.error);
      case RealtimeRemoteVideoFrameEvent(:final realtimeId, :final peerId):
        final session = _sessions[realtimeId];
        if (session == null || session.peerId != peerId) return;
        session._addVideoFrame(
          RealtimeVideoFrame(bytes: event.bytes, timestamp: event.timestamp),
        );
      case RealtimeAudioStateChangedEvent(:final realtimeId, :final peerId):
        final session = _sessions[realtimeId];
        if (session == null || session.peerId != peerId) return;
        session._applyAudioState(event.state);
    }
  }

  Future<SdkResult<void>> _start(_RealtimeSession session) async {
    _ensureUsable();
    return _backend.start(
      realtimeId: session.realtimeId,
      peerId: session.peerId,
    );
  }

  Future<SdkResult<void>> _stop(
    _RealtimeSession session, {
    bool allowDisposed = false,
  }) async {
    if (!allowDisposed) _ensureUsable();
    return _backend.stop(realtimeId: session.realtimeId);
  }

  void _remove(_RealtimeSession session) {
    if (identical(_sessions[session.realtimeId], session)) {
      _sessions.remove(session.realtimeId);
    }
  }

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }
}

final class _RealtimeSession implements RealtimeSession {
  _RealtimeSession({
    required this._client,
    required this.realtimeId,
    required this.peerId,
  });

  final RealtimeClientImpl _client;
  final StreamController<RealtimeVideoFrame> _videoController =
      StreamController<RealtimeVideoFrame>.broadcast();
  RealtimeSessionState _state = RealtimeSessionState.idle;
  RealtimeAudioState _audioState = RealtimeAudioState.unavailable;
  Future<SdkResult<void>>? _startFuture;
  Future<SdkResult<void>>? _stopFuture;
  bool _stopCommandCompleted = false;
  bool _disposed = false;

  @override
  final String realtimeId;

  @override
  final String peerId;

  @override
  RealtimeSessionState get state => _state;

  @override
  Stream<RealtimeVideoFrame> get remoteVideo => _videoController.stream;

  @override
  RealtimeAudioState get audioState => _audioState;

  @override
  Future<SdkResult<void>> start() {
    _ensureUsable();
    final existing = _startFuture;
    if (existing != null) return existing;
    if (_state == RealtimeSessionState.starting ||
        _state == RealtimeSessionState.negotiating ||
        _state == RealtimeSessionState.restarting ||
        _state == RealtimeSessionState.connected) {
      return Future<SdkResult<void>>.value(const SdkSuccess<void>(null));
    }
    _stopCommandCompleted = false;
    _state = RealtimeSessionState.starting;
    final future = _startInternal();
    _startFuture = future;
    future.then<void>(
      (_) {
        if (identical(_startFuture, future)) _startFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_startFuture, future)) _startFuture = null;
      },
    );
    return future;
  }

  Future<SdkResult<void>> _startInternal() async {
    final result = await _client._start(this);
    if (_disposed) return result;
    if (result is SdkFailure<void>) {
      _state = RealtimeSessionState.failed;
    }
    return result;
  }

  @override
  Future<SdkResult<void>> stop() {
    _ensureUsable();
    final existing = _stopFuture;
    if (existing != null) return existing;
    if (_state == RealtimeSessionState.idle ||
        _state == RealtimeSessionState.stopped) {
      return Future<SdkResult<void>>.value(const SdkSuccess<void>(null));
    }
    if (_stopCommandCompleted) {
      return Future<SdkResult<void>>.value(const SdkSuccess<void>(null));
    }
    final future = _stopInternal();
    _stopFuture = future;
    future.then<void>(
      (_) {
        if (identical(_stopFuture, future)) _stopFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_stopFuture, future)) _stopFuture = null;
      },
    );
    return future;
  }

  Future<SdkResult<void>> _stopInternal() async {
    final result = await _client._stop(this);
    if (_disposed) return result;
    if (result is SdkFailure<void>) {
      _state = RealtimeSessionState.failed;
    } else {
      // The command result only confirms native command completion. The
      // authoritative stopped state arrives through the closed state event.
      _stopCommandCompleted = true;
    }
    return result;
  }

  void _applyState(RealtimeSessionState state, NetworkError? error) {
    if (_disposed) return;
    _state = error == null ? state : RealtimeSessionState.failed;
    if (_state == RealtimeSessionState.stopped ||
        _state == RealtimeSessionState.failed) {
      _stopCommandCompleted = false;
    }
  }

  void _addVideoFrame(RealtimeVideoFrame frame) {
    if (_disposed) return;
    _videoController.add(frame);
  }

  void _applyAudioState(RealtimeAudioState state) {
    if (_disposed) return;
    _audioState = state;
  }

  Future<void> _dispose() async {
    if (_disposed) return;
    final shouldStop =
        _state != RealtimeSessionState.idle &&
        _state != RealtimeSessionState.stopped;
    _disposed = true;
    _client._remove(this);
    if (shouldStop) {
      // Disposal must not wait for a command-result timeout. The backend is
      // disposed immediately after all sessions have requested their stop;
      // that cancellation completes any in-flight command futures.
      final stopFuture = _client._stop(this, allowDisposed: true);
      unawaited(
        stopFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    _state = RealtimeSessionState.stopped;
    await _videoController.close();
  }

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }
}

void _validateRealtimeId(String value) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw ArgumentError.value(
      value,
      'realtimeId',
      'Realtime ID must be 16-byte lowercase hexadecimal.',
    );
  }
}
