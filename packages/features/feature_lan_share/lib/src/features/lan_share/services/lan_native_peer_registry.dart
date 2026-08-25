// ignore_for_file: prefer_initializing_formals

import 'package:network_sdk/network_sdk.dart';

import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_peer_trust.dart';

final class LanNativePeerRegistry {
  LanNativePeerRegistry({
    required this.trustStore,
    NetworkFacade? networkFacade,
  }) : _networkFacade = networkFacade;

  final LanPeerTrustStore trustStore;
  NetworkFacade? _networkFacade;
  final Map<String, String> _directEndpoints = <String, String>{};

  /// The registry borrows the App-owned facade for the current runtime
  /// generation. It never starts, stops, or disposes that facade.
  NetworkFacade? get networkFacade => _networkFacade;

  /// Attach the facade after the App runtime has completed configuration.
  void attachFacade(NetworkFacade facade) {
    _networkFacade = facade;
  }

  /// Detach the current facade without touching its lifecycle.
  ///
  /// Direct endpoints are generation-scoped discovery state. Trust records
  /// remain persisted in [trustStore] and will be restored with an empty
  /// endpoint when the next generation is attached.
  void detachFacade() {
    _networkFacade = null;
    _directEndpoints.clear();
  }

  Future<void> restoreAll() async {
    _requireFacade();
    // A restore starts a new native generation. Discovery endpoints are
    // ephemeral and must never leak into the trust-only restore snapshot.
    _directEndpoints.clear();
    for (final record in await trustStore.loadAll()) {
      final result = await _register(record);
      if (result is NetworkFailure<void>) {
        throw StateError(
          'Failed to restore trusted peer ${record.deviceId}: '
          '${result.error.code.name}',
        );
      }
    }
  }

  Future<NetworkResult<void>> registerTrust(LanPeerTrustRecord record) async {
    await trustStore.save(record);
    return _register(record);
  }

  Future<NetworkResult<void>> updateDirectEndpoint(
    String deviceId,
    String endpoint,
  ) async {
    final record = await trustStore.read(deviceId);
    if (record == null) return _missingTrust(deviceId);
    if (_networkFacade == null) return _facadeUnavailable(deviceId);
    final normalized = endpoint.trim();
    if (normalized.isEmpty) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Direct peer endpoint is empty.',
          operation: NetworkOperation.upsertPeer,
          peerId: deviceId,
        ),
      );
    }
    final previous = _directEndpoints[deviceId];
    _directEndpoints[deviceId] = normalized;
    final result = await _register(record);
    if (result is NetworkFailure<void>) {
      if (previous == null) {
        _directEndpoints.remove(deviceId);
      } else {
        _directEndpoints[deviceId] = previous;
      }
    }
    return result;
  }

  Future<NetworkResult<void>> invalidateDirectEndpoint(String deviceId) async {
    final record = await trustStore.read(deviceId);
    if (record == null) return _missingTrust(deviceId);
    final previous = _directEndpoints[deviceId];
    _directEndpoints.remove(deviceId);
    final result = await _register(record);
    if (result is NetworkFailure<void> && previous != null) {
      _directEndpoints[deviceId] = previous;
    }
    return result;
  }

  Future<NetworkResult<void>> authorizeRelayForPeer(String deviceId) async {
    if (await trustStore.read(deviceId) == null) return _missingTrust(deviceId);
    await trustStore.setRelayAuthorization(deviceId, true);
    final record = await trustStore.read(deviceId);
    if (record == null) return _missingTrust(deviceId);
    return _register(record);
  }

  Future<NetworkResult<void>> revokeRelayForPeer(String deviceId) async {
    if (await trustStore.read(deviceId) == null) return _missingTrust(deviceId);
    await trustStore.setRelayAuthorization(deviceId, false);
    final record = await trustStore.read(deviceId);
    if (record == null) return _missingTrust(deviceId);
    return _register(record);
  }

  Future<NetworkResult<void>> removeTrust(String deviceId) async {
    await trustStore.delete(deviceId);
    _directEndpoints.remove(deviceId);
    final facade = _networkFacade;
    if (facade == null) return const NetworkSuccess<void>(null);
    return facade.removePeer(deviceId);
  }

  /// Reconcile discovery's ephemeral native endpoints with trusted peers.
  ///
  /// The discovery snapshot is deliberately not a source of trust. Unknown
  /// devices are ignored, and peers missing from the snapshot are merely
  /// re-registered without a direct endpoint; their trust records remain.
  Future<void> syncDiscoveredEndpoints(
    Iterable<LanDiscoveredPeer> peers,
  ) async {
    final records = await trustStore.loadAll();
    final trustedIds = records.map((record) => record.deviceId).toSet();
    final discovered = <String, String>{};
    for (final peer in peers) {
      if (!trustedIds.contains(peer.deviceId)) continue;
      final nativePort = peer.advertisedNativePort;
      if (nativePort == null || nativePort < 1 || nativePort > 65535) {
        continue;
      }
      final host = peer.ip.trim();
      if (host.isEmpty) continue;
      final endpoint = _formatEndpoint(host, nativePort);
      discovered[peer.deviceId] = endpoint;
    }

    for (final record in records) {
      final endpoint = discovered[record.deviceId];
      if (endpoint == null) {
        if (_directEndpoints.containsKey(record.deviceId)) {
          await invalidateDirectEndpoint(record.deviceId);
        }
        continue;
      }
      if (_directEndpoints[record.deviceId] != endpoint) {
        await updateDirectEndpoint(record.deviceId, endpoint);
      }
    }
  }

  Future<NetworkResult<void>> _register(LanPeerTrustRecord record) {
    final facade = _networkFacade;
    if (facade == null) {
      return Future.value(_facadeUnavailable(record.deviceId));
    }
    return facade.registerPeer(
      PeerConfig(
        peerId: record.deviceId,
        endpointAddress: _directEndpoints[record.deviceId] ?? '',
        identityPublicKey: record.networkIdentityPublicKey,
        e2ePublicKey: record.x25519PublicKey,
        allowDirect: record.authorization.localDirect,
        allowRelay: record.authorization.relay,
      ),
    );
  }

  NetworkFacade _requireFacade() =>
      _networkFacade ??
      (throw StateError('Native network facade is unavailable.'));

  static String _formatEndpoint(String host, int port) {
    final normalizedHost = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    final renderedHost = normalizedHost.contains(':')
        ? '[$normalizedHost]'
        : normalizedHost;
    return '$renderedHost:$port';
  }

  NetworkFailure<void> _missingTrust(String deviceId) => NetworkFailure<void>(
    NetworkError(
      code: NetworkErrorCode.authenticationFailed,
      message: 'Peer trust is unavailable.',
      operation: NetworkOperation.upsertPeer,
      peerId: deviceId,
    ),
  );

  NetworkFailure<void> _facadeUnavailable(String deviceId) =>
      NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'Native network facade is unavailable.',
          operation: NetworkOperation.upsertPeer,
          peerId: deviceId,
        ),
      );
}
