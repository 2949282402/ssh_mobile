// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:uuid/uuid.dart';

import 'lan_peer_trust.dart';
import 'lan_network_models.dart';
import 'lan_share_models.dart';
import 'lan_transfer_protocol.dart';
import 'lan_transfer_service.dart';

/// Owns the complete Network V2 binary-transfer orchestration for LAN Share.
///
/// The coordinator is intentionally the only feature object that knows how to
/// turn an authenticated LAN capability snapshot into a native peer endpoint.
/// View models receive a result and an event stream; they never hold a facade,
/// peer configuration, capability cache, or native-port cache.
final class LanNativeTransferCoordinator {
  LanNativeTransferCoordinator({
    required LanTransferService transferService,
    required NetworkFacade networkFacade,
    required LanPeerTrustStore trustStore,
    required Future<NetworkResult<void>> Function(
      String deviceId,
      String endpoint,
    )
    updateDirectEndpoint,
    required Future<NetworkResult<void>> Function(String deviceId)
    invalidateDirectEndpoint,
    Future<NetworkResult<void>> Function(String deviceId)? removeTrust,
    Future<NetworkResult<void>> Function(String deviceId, bool enabled)?
    setRelayAuthorization,
    this.offerTimeout = const Duration(seconds: 25),
  }) : _transferService = transferService,
       _networkFacade = networkFacade,
       _trustStore = trustStore,
       _updateDirectEndpoint = updateDirectEndpoint,
       _invalidateDirectEndpoint = invalidateDirectEndpoint,
       _removeTrust = removeTrust,
       _setRelayAuthorization = setRelayAuthorization {
    _networkSubscription = _networkFacade.events.listen(
      _handleNetworkEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (!_events.isClosed) _events.addError(error, stackTrace);
      },
    );
  }

  /// Authenticated LAN HTTPS capability/control service.
  final LanTransferService _transferService;

  /// App-scope Network V2 facade borrowed for the coordinator lifetime.
  final NetworkFacade _networkFacade;

  /// Atomic peer trust source. No trust means no binary transfer.
  final LanPeerTrustStore _trustStore;

  /// Updates the runtime-generation-scoped direct endpoint in the peer registry.
  final Future<NetworkResult<void>> Function(String deviceId, String endpoint)
  _updateDirectEndpoint;

  /// Invalidates a stale endpoint after a capability or connect failure.
  final Future<NetworkResult<void>> Function(String deviceId)
  _invalidateDirectEndpoint;

  /// Explicit trust revoke hook, normally backed by LanNativePeerRegistry.
  ///
  /// When omitted, the coordinator performs the same operation directly so
  /// callers that do not use the registry still fail closed.
  final Future<NetworkResult<void>> Function(String deviceId)? _removeTrust;

  /// Sets the persistent and native Relay authorization for a trusted peer.
  final Future<NetworkResult<void>> Function(String deviceId, bool enabled)?
  _setRelayAuthorization;

  /// Time after which an unanswered incoming offer is rejected.
  final Duration offerTimeout;

  final _incomingOffers = StreamController<IncomingTransferOffer>.broadcast();
  final _events = StreamController<SdkEvent>.broadcast();
  final Map<String, IncomingTransferOffer> _pendingOffers = {};
  final Map<String, Timer> _offerTimers = {};
  final Map<String, bool> _committedDecisions = {};
  final Map<String, _IncomingDecisionOperation> _decisionOperations = {};
  StreamSubscription<SdkEvent>? _networkSubscription;
  bool _disposed = false;

  /// Native offers that still require one user decision.
  Stream<IncomingTransferOffer> get incomingOffers => _incomingOffers.stream;

  /// Native transfer progress/completion/failure and other V2 events.
  Stream<SdkEvent> get events => _events.stream;

  /// Sends one regular file through Network V2 only.
  ///
  /// Directories and multi-file manifests are intentionally rejected until a
  /// corresponding native V2 protocol exists; no HTTPS binary fallback exists.
  Future<NetworkResult<TransferSession>> sendFile(
    LanDiscoveredPeer device,
    String filePath,
  ) async {
    if (_disposed) {
      return _failure(
        code: NetworkErrorCode.cancelled,
        message: 'Native transfer coordinator is disposed.',
        operation: NetworkOperation.sendFile,
        peerId: device.deviceId,
      );
    }

    final file = File(filePath);
    final validation = await _validateSourceFile(file, device.deviceId);
    if (validation != null) return validation;

    LanPeerTrustRecord? trust;
    try {
      trust = await _trustStore.read(device.deviceId);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.sendFile,
          peerId: device.deviceId,
        ),
      );
    }
    if (trust == null) {
      return _failure(
        code: NetworkErrorCode.authenticationFailed,
        message: 'Peer trust is unavailable.',
        operation: NetworkOperation.sendFile,
        peerId: device.deviceId,
      );
    }
    final capability = await _fetchCapabilities(device, trust);
    if (capability is NetworkFailure<_NativeCapability>) {
      final invalidation = await _invalidate(device.deviceId);
      if (trust.authorization.relay &&
          invalidation is NetworkSuccess<void> &&
          _canFallbackToRelay(capability.error.code)) {
        return _connectAndTransfer(device, file);
      }
      return NetworkFailure<TransferSession>(capability.error);
    }
    final snapshot = (capability as NetworkSuccess<_NativeCapability>).data;
    final endpoint = _formatEndpoint(device.ip, snapshot.nativePort);

    late final NetworkResult<void> registerResult;
    try {
      registerResult = await _updateDirectEndpoint(device.deviceId, endpoint);
    } catch (error) {
      await _invalidateQuietly(device.deviceId);
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.upsertPeer,
          peerId: device.deviceId,
        ),
      );
    }
    if (registerResult is NetworkFailure<void>) {
      // The registry updates its generation-scoped endpoint before asking the
      // facade to register it.  Clear that candidate when registration fails
      // so a later transfer cannot accidentally reuse a rejected endpoint.
      await _invalidateQuietly(device.deviceId);
      return NetworkFailure<TransferSession>(registerResult.error);
    }

    return _connectAndTransfer(device, file);
  }

  Future<NetworkResult<TransferSession>> _connectAndTransfer(
    LanDiscoveredPeer device,
    File file,
  ) async {
    late final NetworkResult<void> connectResult;
    try {
      connectResult = await _networkFacade.connectPeer(
        device.deviceId,
        communicationClass: CommunicationClass.bulkTransfer,
      );
    } catch (error) {
      await _invalidateQuietly(device.deviceId);
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.connect,
          peerId: device.deviceId,
        ),
      );
    }
    if (connectResult is NetworkFailure<void>) {
      await _invalidateQuietly(device.deviceId);
      return NetworkFailure<TransferSession>(connectResult.error);
    }

    try {
      return await _networkFacade.transferFile(
        transferId: const Uuid().v4(),
        peerId: device.deviceId,
        filePath: file.absolute.path,
        communicationClass: CommunicationClass.bulkTransfer,
      );
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.sendFile,
          peerId: device.deviceId,
        ),
      );
    }
  }

  /// Accepts a native offer only when the peer still has complete trust.
  Future<NetworkResult<void>> accept(IncomingTransferOffer offer) =>
      _respond(offer, accept: true);

  /// Rejects a native offer. Repeated identical decisions are idempotent.
  Future<NetworkResult<void>> reject(IncomingTransferOffer offer) =>
      _respond(offer, accept: false);

  /// Explicitly revokes trust and removes the native peer configuration.
  Future<NetworkResult<void>> removeTrustedPeer(String deviceId) async {
    if (_disposed) {
      return _failure(
        code: NetworkErrorCode.cancelled,
        message: 'Native transfer coordinator is disposed.',
        operation: NetworkOperation.removePeer,
        peerId: deviceId,
      );
    }
    final callback = _removeTrust;
    if (callback != null) {
      try {
        return await callback(deviceId);
      } catch (error) {
        return NetworkFailure(
          lanNetworkError(
            error,
            operation: NetworkOperation.removePeer,
            peerId: deviceId,
          ),
        );
      }
    }
    try {
      await _trustStore.delete(deviceId);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.removePeer,
          peerId: deviceId,
        ),
      );
    }
    try {
      return await _networkFacade.removePeer(deviceId);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.removePeer,
          peerId: deviceId,
        ),
      );
    }
  }

  /// Sets the persistent and native Relay authorization for a trusted peer.
  Future<NetworkResult<void>> setRelayAuthorization({
    required String peerId,
    required bool enabled,
  }) async {
    final setAuth = _setRelayAuthorization;
    if (setAuth != null) {
      return setAuth(peerId, enabled);
    }
    if (enabled) {
      try {
        await _trustStore.setRelayAuthorization(peerId, true);
        return const NetworkSuccess<void>(null);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: peerId,
          ),
        );
      }
    } else {
      try {
        await _trustStore.setRelayAuthorization(peerId, false);
        return const NetworkSuccess<void>(null);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: peerId,
          ),
        );
      }
    }
  }

  /// Closes subscriptions and offer timers without disposing the App facade.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _offerTimers.values) {
      timer.cancel();
    }
    _offerTimers.clear();
    _pendingOffers.clear();
    _decisionOperations.clear();
    _committedDecisions.clear();
    await _networkSubscription?.cancel();
    await _incomingOffers.close();
    await _events.close();
  }

  Future<NetworkResult<TransferSession>?> _validateSourceFile(
    File file,
    String peerId,
  ) async {
    try {
      if (!await file.exists()) {
        return _failure(
          code: NetworkErrorCode.ioError,
          message: 'Source file is unavailable.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        return _failure(
          code: NetworkErrorCode.invalidArgument,
          message: 'Only regular files can be sent through Network V2.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      final name = file.uri.pathSegments.isEmpty
          ? ''
          : file.uri.pathSegments.last;
      if (name.isEmpty || name == '.' || name == '..') {
        return _failure(
          code: NetworkErrorCode.invalidArgument,
          message: 'Source file name is invalid.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      return null;
    } catch (error) {
      return _failure(
        code: NetworkErrorCode.ioError,
        message: 'Source file cannot be inspected.',
        operation: NetworkOperation.sendFile,
        peerId: peerId,
      );
    }
  }

  Future<NetworkResult<_NativeCapability>> _fetchCapabilities(
    LanDiscoveredPeer device,
    LanPeerTrustRecord trust,
  ) async {
    HttpClient? client;
    try {
      client = await _transferService.createHttpClientForPeer(
        device.deviceId,
        expectedFingerprint: trust.certificateFingerprint,
      );
      final host = _normalizeHost(device.ip);
      final request = await client
          .getUrl(
            Uri(
              scheme: 'https',
              host: host,
              port: device.controlPort,
              path: '/api/lan/capabilities',
            ),
          )
          .timeout(const Duration(seconds: 4));
      request.followRedirects = false;
      request.headers.set('x-device-id', _transferService.currentDeviceId);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${trust.outboundAccessToken}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final body = await _transferService.readBoundedJsonResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        throw lanHttpException(
          statusCode: response.statusCode,
          body: body,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
          fallbackMessage: 'LAN capability query failed.',
        );
      }
      final protocolVersion = body['protocolVersion'];
      if (protocolVersion != LanControlProtocol.version) {
        throw LanNetworkException(
          'Unsupported LAN Control protocol version: $protocolVersion (expected ${LanControlProtocol.version})',
          code: NetworkErrorCode.protocolMismatch,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        );
      }
      if (body['e2eEncryption'] != true || body['quicFileTransfer'] != true) {
        throw const LanNetworkException(
          'Recipient native file transfer is unavailable.',
          code: NetworkErrorCode.noRoute,
          operation: NetworkOperation.fetchCapabilities,
        );
      }
      final x25519 = _decodePublicKey(body['x25519PubKey']);
      final identity = _decodePublicKey(body['networkIdentityPubKey']);
      if (!listEquals(x25519, trust.x25519PublicKey) ||
          !listEquals(identity, trust.networkIdentityPublicKey)) {
        throw LanNetworkException(
          'Recipient identity conflicts with the paired trust record.',
          code: NetworkErrorCode.identityConflict,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        );
      }
      final nativePort = (body['quicPort'] as num?)?.toInt();
      if (nativePort == null || nativePort < 1 || nativePort > 65535) {
        throw LanNetworkException(
          'Recipient native transfer endpoint is unavailable.',
          code: NetworkErrorCode.noRoute,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        );
      }
      return NetworkSuccess(_NativeCapability(nativePort));
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        ),
      );
    } finally {
      client?.close();
    }
  }

  Future<NetworkResult<void>> _respond(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    if (_disposed) {
      return _failure(
        code: NetworkErrorCode.cancelled,
        message: 'Native transfer coordinator is disposed.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }
    final committed = _committedDecisions[offer.transferId];
    if (committed != null) {
      if (committed == accept) return const NetworkSuccess<void>(null);
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Incoming transfer already has a different decision.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final inFlight = _decisionOperations[offer.transferId];
    if (inFlight != null) {
      if (inFlight.accept == accept) {
        return inFlight.future;
      }
      return _failure(
        code: NetworkErrorCode.invalidState,
        message: 'A conflicting decision is currently in flight.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final completer = Completer<NetworkResult<void>>();
    _decisionOperations[offer.transferId] = _IncomingDecisionOperation(
      accept: accept,
      future: completer.future,
    );

    try {
      final result = await _executeRespond(offer, accept: accept);
      completer.complete(result);
      return result;
    } catch (error) {
      final failure = NetworkFailure<void>(
        lanNetworkError(
          error,
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        ),
      );
      completer.complete(failure);
      return failure;
    } finally {
      if (identical(
        _decisionOperations[offer.transferId]?.future,
        completer.future,
      )) {
        _decisionOperations.remove(offer.transferId);
      }
    }
  }

  Future<NetworkResult<void>> _executeRespond(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    LanPeerTrustRecord? trust;
    try {
      trust = await _trustStore.read(offer.peerId);
    } catch (error) {
      final nativeRes = await _respondNative(offer, accept: false);
      if (nativeRes is NetworkSuccess<void>) {
        _committedDecisions[offer.transferId] = false;
        _pendingOffers.remove(offer.transferId);
        _offerTimers.remove(offer.transferId)?.cancel();
      }
      return NetworkFailure<void>(
        lanNetworkError(
          error,
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        ),
      );
    }

    final isAuthorized =
        trust != null && _isIncomingRouteAuthorized(trust, offer.routeType);

    if (!isAuthorized) {
      final nativeRes = await _respondNative(offer, accept: false);
      if (nativeRes is NetworkSuccess<void>) {
        _committedDecisions[offer.transferId] = false;
        _pendingOffers.remove(offer.transferId);
        _offerTimers.remove(offer.transferId)?.cancel();
      }
      return _failure(
        code: NetworkErrorCode.authenticationFailed,
        message: 'Incoming transfer peer is not trusted.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final nativeResult = await _respondNative(offer, accept: accept);
    if (nativeResult is NetworkSuccess<void>) {
      _committedDecisions[offer.transferId] = accept;
      _pendingOffers.remove(offer.transferId);
      _offerTimers.remove(offer.transferId)?.cancel();
    }
    return nativeResult;
  }

  Future<NetworkResult<void>> _respondNative(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    try {
      return await _networkFacade.respondToIncomingTransfer(
        transferId: offer.transferId,
        accept: accept,
      );
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        ),
      );
    }
  }

  Future<void> _expireOffer(IncomingTransferOffer offer) async {
    if (_disposed) return;
    final inFlight = _decisionOperations[offer.transferId];
    if (inFlight != null) {
      try {
        await inFlight.future;
      } catch (_) {}
    }
    if (!_disposed &&
        !_committedDecisions.containsKey(offer.transferId) &&
        _pendingOffers.containsKey(offer.transferId)) {
      await reject(offer);
    }
  }

  void _handleNetworkEvent(SdkEvent event) {
    if (_disposed) return;
    if (event case final IncomingTransferOffer offer) {
      if (_pendingOffers.containsKey(offer.transferId) ||
          _committedDecisions.containsKey(offer.transferId) ||
          _decisionOperations.containsKey(offer.transferId)) {
        return;
      }
      _pendingOffers[offer.transferId] = offer;
      _offerTimers[offer.transferId] = Timer(offerTimeout, () {
        unawaited(_expireOffer(offer));
      });
      if (!_incomingOffers.isClosed) _incomingOffers.add(offer);
    }
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _invalidateQuietly(String deviceId) async {
    await _invalidate(deviceId);
  }

  Future<NetworkResult<void>> _invalidate(String deviceId) async {
    try {
      return await _invalidateDirectEndpoint(deviceId);
    } on Object catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.upsertPeer,
          peerId: deviceId,
        ),
      );
    }
  }

  static Uint8List _decodePublicKey(Object? value) {
    if (value is! String) {
      throw const FormatException('Native capability key is missing.');
    }
    final decoded = base64.decode(value);
    if (decoded.length != 32) {
      throw const FormatException('Native capability key is invalid.');
    }
    return Uint8List.fromList(decoded);
  }

  static String _normalizeHost(String rawHost) {
    final host = rawHost.trim();
    if (host.startsWith('[') && host.endsWith(']')) {
      return host.substring(1, host.length - 1);
    }
    if (host.isEmpty ||
        host.length > 253 ||
        RegExp(r'[\x00-\x20/@?#\\\[\]]').hasMatch(host)) {
      throw const FormatException('LAN peer address is invalid.');
    }
    return host;
  }

  static String _formatEndpoint(String rawHost, int port) {
    final host = _normalizeHost(rawHost);
    return host.contains(':') ? '[$host]:$port' : '$host:$port';
  }

  static bool _isIncomingRouteAuthorized(
    LanPeerTrustRecord trust,
    NetworkRouteType routeType,
  ) => switch (routeType) {
    NetworkRouteType.relay => trust.authorization.relay,
    NetworkRouteType.lan ||
    NetworkRouteType.quicDirect => trust.authorization.localDirect,
    NetworkRouteType.unspecified =>
      trust.authorization.localDirect || trust.authorization.relay,
  };

  static bool _canFallbackToRelay(NetworkErrorCode code) => switch (code) {
    NetworkErrorCode.noRoute ||
    NetworkErrorCode.timeout ||
    NetworkErrorCode.peerOffline ||
    NetworkErrorCode.ioError ||
    NetworkErrorCode.pathLost => true,
    _ => false,
  };

  static NetworkFailure<T> _failure<T>({
    required NetworkErrorCode code,
    required String message,
    required NetworkOperation operation,
    String? peerId,
  }) => NetworkFailure<T>(
    NetworkError(
      code: code,
      message: message,
      operation: operation,
      peerId: peerId,
    ),
  );
}

final class _NativeCapability {
  const _NativeCapability(this.nativePort);

  final int nativePort;
}

final class _IncomingDecisionOperation {
  const _IncomingDecisionOperation({
    required this.accept,
    required this.future,
  });

  final bool accept;
  final Future<NetworkResult<void>> future;
}
