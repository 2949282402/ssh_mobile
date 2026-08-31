part of 'lan_native_peer_registry.dart';

/// Runtime-generation discovery observations and endpoint pruning.
extension LanNativePeerRegistryObservation on LanNativePeerRegistry {
  Future<NetworkResult<void>> _updateDirectEndpoint(
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

  Future<NetworkResult<void>> _invalidateDirectEndpoint(String deviceId) {
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

  Future<void> _syncDiscoveredEndpoints(
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
      discovered[peer.deviceId] = _formatNativeEndpoint(host, nativePort);
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

  Future<void> _observeDiscoveredEndpoint(LanDiscoveredPeer peer) async {
    final records = await trustStore.loadAll();
    LanPeerTrustRecord? record;
    for (final candidate in records) {
      if (candidate.deviceId == peer.deviceId) {
        record = candidate;
        break;
      }
    }
    if (record == null ||
        _revokedPeerIds.contains(peer.deviceId) ||
        _blockedPeerIds.contains(peer.deviceId)) {
      return;
    }

    final nativePort = peer.advertisedNativePort;
    final host = peer.ip.trim();
    if (nativePort == null ||
        nativePort < 1 ||
        nativePort > 65535 ||
        host.isEmpty) {
      if (_directEndpoints.containsKey(peer.deviceId)) {
        await invalidateDirectEndpoint(peer.deviceId);
      }
      return;
    }

    final endpoint = _formatNativeEndpoint(host, nativePort);
    if (_directEndpoints[peer.deviceId] != endpoint) {
      await updateDirectEndpoint(peer.deviceId, endpoint);
    }
  }
}

String _formatNativeEndpoint(String host, int port) {
  final normalizedHost = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final renderedHost = normalizedHost.contains(':')
      ? '[$normalizedHost]'
      : normalizedHost;
  return '$renderedHost:$port';
}

String? _endpointKey(String host, int port) {
  if (port < 1 || port > 65535) return null;
  final normalized = _hostKey(host);
  return normalized == null ? null : '$normalized:$port';
}

String? _hostKey(String host) {
  var normalized = host.trim();
  if (normalized.isEmpty) return null;
  if (normalized.startsWith('[') && normalized.endsWith(']')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  if (normalized.isEmpty || normalized.contains('/')) return null;
  return normalized.toLowerCase();
}

String? _hostKeyFromEndpoint(String endpoint) {
  final normalized = endpoint.trim();
  if (normalized.isEmpty) return null;
  if (normalized.startsWith('[')) {
    final close = normalized.indexOf(']');
    if (close <= 1 ||
        close + 2 > normalized.length ||
        normalized[close + 1] != ':') {
      return null;
    }
    return _hostKey(normalized.substring(1, close));
  }
  final separator = normalized.lastIndexOf(':');
  return separator <= 0 ? null : _hostKey(normalized.substring(0, separator));
}

String? _endpointKeyFromEndpoint(String endpoint) {
  final normalized = endpoint.trim();
  if (normalized.isEmpty) return null;
  if (normalized.startsWith('[')) {
    final close = normalized.indexOf(']');
    if (close <= 1 ||
        close + 2 > normalized.length ||
        normalized[close + 1] != ':') {
      return null;
    }
    final host = normalized.substring(1, close);
    final port = int.tryParse(normalized.substring(close + 2));
    return port == null ? null : _endpointKey(host, port);
  }
  final separator = normalized.lastIndexOf(':');
  if (separator <= 0 || separator == normalized.length - 1) return null;
  final port = int.tryParse(normalized.substring(separator + 1));
  return port == null
      ? null
      : _endpointKey(normalized.substring(0, separator), port);
}
