// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:network_sdk/network_sdk.dart';

import '../../../services/lan_share/lan_network_models.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_peer_trust.dart';

final class LanNativePeerRegistry implements LanNativePeerPolicyPort {
  LanNativePeerRegistry({
    required this.trustStore,
    NetworkFacade? networkFacade,
  }) : _networkFacade = networkFacade;

  final LanPeerTrustStore trustStore;
  NetworkFacade? _networkFacade;
  final Map<String, String> _directEndpoints = <String, String>{};
  final Map<String, Future<void>> _peerMutationSerial =
      <String, Future<void>>{};
  final Set<String> _revokedPeerIds = <String>{};
  final Set<String> _blockedPeerIds = <String>{};

  /// Whether the peer is currently blocked in this runtime generation due to
  /// failed native peer cleanup or failed reconciliation.
  bool isPeerBlocked(String deviceId) => _blockedPeerIds.contains(deviceId);

  /// Whether the peer has been explicitly revoked in this runtime generation.
  bool isPeerRevoked(String deviceId) => _revokedPeerIds.contains(deviceId);

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

  /// Restores all persisted trust records into the current native generation
  /// with peer-isolated failure handling.
  Future<LanPeerRestoreReport> restoreAll() async {
    _requireFacade();
    // A restore starts a new native generation. Discovery endpoints are
    // ephemeral and must never leak into the trust-only restore snapshot.
    _directEndpoints.clear();
    final List<LanPeerTrustRecord> records;
    try {
      records = await trustStore.loadAll();
    } catch (error) {
      throw StateError('Failed to load trust records during restore: $error');
    }

    final restored = <String>[];
    final blocked = <String>[];
    final failures = <String, NetworkError>{};

    for (final record in records) {
      if (_revokedPeerIds.contains(record.deviceId)) continue;
      final result = await _register(record);
      if (result is NetworkSuccess<void>) {
        _blockedPeerIds.remove(record.deviceId);
        restored.add(record.deviceId);
      } else if (result is NetworkFailure<void>) {
        _blockedPeerIds.add(record.deviceId);
        blocked.add(record.deviceId);
        failures[record.deviceId] = result.error;
      }
    }

    return LanPeerRestoreReport(
      restoredPeerIds: restored,
      blockedPeerIds: blocked,
      failures: failures,
    );
  }

  @override
  Future<NetworkResult<LanPeerPolicySnapshot>> getPeerPolicy(
    String peerId,
  ) async {
    if (_revokedPeerIds.contains(peerId)) {
      return NetworkSuccess<LanPeerPolicySnapshot>(
        LanPeerPolicySnapshot(
          trust: null,
          runtimeBlocked: _blockedPeerIds.contains(peerId),
          revoked: true,
        ),
      );
    }
    final isBlocked = _blockedPeerIds.contains(peerId);
    final LanPeerTrustRecord? record;
    try {
      record = await trustStore.read(peerId);
    } catch (error) {
      return NetworkFailure<LanPeerPolicySnapshot>(
        lanNetworkError(
          error,
          operation: NetworkOperation.upsertPeer,
          peerId: peerId,
        ),
      );
    }
    return NetworkSuccess<LanPeerPolicySnapshot>(
      LanPeerPolicySnapshot(
        trust: record,
        runtimeBlocked: isBlocked,
        revoked: false,
      ),
    );
  }

  @override
  Future<NetworkResult<void>> reconcilePersistedTrust(
    LanPeerTrustRecord record,
  ) {
    return _serializePeerMutation(record.deviceId, () async {
      final result = await _register(record);
      if (result is NetworkSuccess<void>) {
        _revokedPeerIds.remove(record.deviceId);
        _blockedPeerIds.remove(record.deviceId);
      } else {
        _blockedPeerIds.add(record.deviceId);
      }
      return result;
    });
  }

  @override
  Future<NetworkResult<void>> updateDirectEndpoint(
    String deviceId,
    String endpoint,
  ) {
    return _serializePeerMutation(deviceId, () async {
      if (_revokedPeerIds.contains(deviceId)) return _missingTrust(deviceId);
      if (_blockedPeerIds.contains(deviceId)) return _peerBlocked(deviceId);
      final LanPeerTrustRecord? record;
      try {
        record = await trustStore.read(deviceId);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: deviceId,
          ),
        );
      }
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
    });
  }

  @override
  Future<NetworkResult<void>> invalidateDirectEndpoint(String deviceId) {
    return _serializePeerMutation(deviceId, () async {
      if (_revokedPeerIds.contains(deviceId)) return _missingTrust(deviceId);
      if (_blockedPeerIds.contains(deviceId)) return _peerBlocked(deviceId);
      final LanPeerTrustRecord? record;
      try {
        record = await trustStore.read(deviceId);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: deviceId,
          ),
        );
      }
      if (record == null) return _missingTrust(deviceId);
      final previous = _directEndpoints[deviceId];
      _directEndpoints.remove(deviceId);
      final result = await _register(record);
      if (result is NetworkFailure<void> && previous != null) {
        _directEndpoints[deviceId] = previous;
      }
      return result;
    });
  }

  @override
  Future<NetworkResult<void>> setRelayAuthorization(
    String deviceId,
    bool enabled,
  ) {
    return enabled
        ? authorizeRelayForPeer(deviceId)
        : revokeRelayForPeer(deviceId);
  }

  Future<NetworkResult<void>> authorizeRelayForPeer(String deviceId) {
    return _serializePeerMutation(deviceId, () async {
      if (_revokedPeerIds.contains(deviceId)) return _missingTrust(deviceId);
      if (_blockedPeerIds.contains(deviceId)) return _peerBlocked(deviceId);
      final LanPeerTrustRecord? current;
      try {
        current = await trustStore.read(deviceId);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: deviceId,
          ),
        );
      }
      if (current == null) return _missingTrust(deviceId);
      if (current.authorization.relay) return const NetworkSuccess<void>(null);

      final proposed = current.copyWith(
        authorization: current.authorization.copyWith(relay: true),
      );
      final nativeResult = await _register(proposed);
      if (nativeResult is NetworkFailure<void>) {
        return nativeResult;
      }

      try {
        await trustStore.save(proposed);
        return const NetworkSuccess<void>(null);
      } catch (error) {
        final rollbackResult = await _register(current);
        if (rollbackResult is NetworkFailure<void>) {
          final removed = await _forceRemoveNativePeer(deviceId);
          if (!removed) {
            _blockedPeerIds.add(deviceId);
          }
        }
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: deviceId,
          ),
        );
      }
    });
  }

  Future<NetworkResult<void>> revokeRelayForPeer(String deviceId) {
    return _serializePeerMutation(deviceId, () async {
      if (_revokedPeerIds.contains(deviceId)) return _missingTrust(deviceId);
      if (_blockedPeerIds.contains(deviceId)) return _peerBlocked(deviceId);
      final LanPeerTrustRecord? current;
      try {
        current = await trustStore.read(deviceId);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: deviceId,
          ),
        );
      }
      if (current == null) return _missingTrust(deviceId);
      if (!current.authorization.relay) return const NetworkSuccess<void>(null);

      final updated = current.copyWith(
        authorization: current.authorization.copyWith(relay: false),
      );
      try {
        await trustStore.save(updated);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.upsertPeer,
            peerId: deviceId,
          ),
        );
      }

      final nativeResult = await _register(updated);
      if (nativeResult is NetworkFailure<void>) {
        final removed = await _forceRemoveNativePeer(deviceId);
        if (!removed) {
          _blockedPeerIds.add(deviceId);
        }
        return nativeResult;
      }
      return const NetworkSuccess<void>(null);
    });
  }

  @override
  Future<NetworkResult<void>> removeTrust(String deviceId) {
    return _serializePeerMutation(deviceId, () async {
      _revokedPeerIds.add(deviceId);
      _blockedPeerIds.remove(deviceId);
      try {
        await trustStore.delete(deviceId);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.removePeer,
            peerId: deviceId,
          ),
        );
      }
      _directEndpoints.remove(deviceId);
      final facade = _networkFacade;
      if (facade == null) return const NetworkSuccess<void>(null);
      try {
        await facade.disconnectPeer(deviceId);
      } catch (_) {}
      try {
        return await facade.removePeer(deviceId);
      } catch (error) {
        return NetworkFailure<void>(
          lanNetworkError(
            error,
            operation: NetworkOperation.removePeer,
            peerId: deviceId,
          ),
        );
      }
    });
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
    final trustedIds = records
        .map((record) => record.deviceId)
        .where(
          (id) =>
              !_revokedPeerIds.contains(id) && !_blockedPeerIds.contains(id),
        )
        .toSet();
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
      if (_revokedPeerIds.contains(record.deviceId)) continue;
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

  Future<T> _serializePeerMutation<T>(
    String peerId,
    Future<T> Function() operation,
  ) async {
    final previous = _peerMutationSerial[peerId] ?? Future<void>.value();
    final completer = Completer<void>();
    _peerMutationSerial[peerId] = completer.future;
    try {
      await previous;
      return await operation();
    } finally {
      completer.complete();
      if (identical(_peerMutationSerial[peerId], completer.future)) {
        _peerMutationSerial.remove(peerId);
      }
    }
  }

  Future<NetworkResult<void>> _register(LanPeerTrustRecord record) async {
    final facade = _networkFacade;
    if (facade == null) {
      return _facadeUnavailable(record.deviceId);
    }
    try {
      return await facade.registerPeer(
        PeerConfig(
          peerId: record.deviceId,
          endpointAddress: _directEndpoints[record.deviceId] ?? '',
          identityPublicKey: record.networkIdentityPublicKey,
          e2ePublicKey: record.x25519PublicKey,
          allowDirect: record.authorization.localDirect,
          allowRelay: record.authorization.relay,
        ),
      );
    } catch (error) {
      return NetworkFailure<void>(
        lanNetworkError(
          error,
          operation: NetworkOperation.upsertPeer,
          peerId: record.deviceId,
        ),
      );
    }
  }

  Future<bool> _forceRemoveNativePeer(String peerId) async {
    final facade = _networkFacade;
    if (facade == null) return true;
    try {
      await facade.disconnectPeer(peerId);
    } catch (_) {}
    try {
      final result = await facade.removePeer(peerId);
      return result is NetworkSuccess<void>;
    } catch (_) {
      return false;
    }
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

  NetworkFailure<void> _peerBlocked(String deviceId) => NetworkFailure<void>(
    NetworkError(
      code: NetworkErrorCode.securityPolicyMismatch,
      message:
          'Peer is runtime-blocked due to inconsistent native authorization state.',
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
