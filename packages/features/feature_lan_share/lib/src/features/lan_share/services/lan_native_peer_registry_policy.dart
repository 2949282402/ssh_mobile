part of 'lan_native_peer_registry.dart';

/// Trust restoration, authorization mutation, and native registration policy.
extension LanNativePeerRegistryPolicy on LanNativePeerRegistry {
  /// Restores all persisted trust records into the current native generation
  /// with peer-isolated failure handling.
  Future<LanPeerRestoreReport> _restoreAll() async {
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

  Future<NetworkResult<LanPeerPolicySnapshot>> _getPeerPolicy(
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

  Future<NetworkResult<void>> _reconcilePersistedTrust(
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

  Future<NetworkResult<void>> _authorizeRelayForPeer(String deviceId) {
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
      if (nativeResult is NetworkFailure<void>) return nativeResult;

      try {
        await trustStore.save(proposed);
        return const NetworkSuccess<void>(null);
      } catch (error) {
        final rollbackResult = await _register(current);
        if (rollbackResult is NetworkFailure<void>) {
          final removed = await _forceRemoveNativePeer(deviceId);
          if (!removed) _blockedPeerIds.add(deviceId);
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

  Future<NetworkResult<void>> _revokeRelayForPeer(String deviceId) {
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
        if (!removed) _blockedPeerIds.add(deviceId);
        return nativeResult;
      }
      return const NetworkSuccess<void>(null);
    });
  }

  Future<NetworkResult<void>> _removeTrust(String deviceId) {
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
    if (facade == null) return _facadeUnavailable(record.deviceId);
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
