part of 'network_service.dart';

/// 事件驱动的 Peer/Route/Transfer projection；不发送命令也不拥有 Runtime。
final class _NetworkStateProjection {
  final Map<String, String> _transferPeers = <String, String>{};
  final Map<String, NetworkRouteType> _peerRoutes =
      <String, NetworkRouteType>{};
  final Map<String, RouteSnapshot> _routes = <String, RouteSnapshot>{};

  bool hasRoute(String peerId) => _peerRoutes.containsKey(peerId);

  RouteSnapshot? routeFor(String peerId) => _routes[peerId];

  NetworkRouteType routeTypeFor(String peerId) =>
      _peerRoutes[peerId] ?? NetworkRouteType.unspecified;

  void trackTransfer(String transferId, String peerId) {
    _transferPeers[transferId] = peerId;
  }

  void untrackTransfer(String transferId) {
    _transferPeers.remove(transferId);
  }

  /// 应用一个公开事件并返回需要补发的 Relay 路由失效事件。
  _NetworkProjectionUpdate apply(NetworkEvent event) {
    final invalidatedRelayPeers = <String>[];
    NetworkError? relayError;
    if (event case PeerStateChanged(
      :final peerId,
      :final state,
      :final routeType,
      :final routeTopology,
      :final routeTransport,
    )) {
      if (state == PeerConnectionState.connected) {
        _peerRoutes[peerId] = routeType;
        _routes[peerId] = RouteSnapshot(
          peerId: peerId,
          routeType: routeType,
          topology: routeTopology,
          transport: routeTransport,
        );
      } else if (state == PeerConnectionState.disconnected ||
          state == PeerConnectionState.failed) {
        _peerRoutes.remove(peerId);
        _routes.remove(peerId);
      }
    } else if (event case RouteChanged(:final snapshot)) {
      _peerRoutes[snapshot.peerId] = snapshot.routeType;
      _routes[snapshot.peerId] = snapshot;
    } else if (event case IncomingTransferOffer(
      :final transferId,
      :final peerId,
    )) {
      trackTransfer(transferId, peerId);
    } else if (event case RelayStateChanged(:final state, :final error)) {
      relayError = error;
      if (state == RelayConnectionState.failed ||
          state == RelayConnectionState.disconnected) {
        for (final entry in _peerRoutes.entries.toList()) {
          if (entry.value != NetworkRouteType.relay) continue;
          invalidatedRelayPeers.add(entry.key);
          _peerRoutes.remove(entry.key);
          _routes.remove(entry.key);
        }
      }
    } else if (event
        case TransferCompleted(:final transferId) ||
            TransferFailed(:final transferId)) {
      untrackTransfer(transferId);
    }
    return _NetworkProjectionUpdate(
      invalidatedRelayPeers: invalidatedRelayPeers,
      relayError: relayError,
    );
  }
}

/// Projection 对事件路由器的增量结果。
final class _NetworkProjectionUpdate {
  const _NetworkProjectionUpdate({
    required this.invalidatedRelayPeers,
    required this.relayError,
  });

  final List<String> invalidatedRelayPeers;
  final NetworkError? relayError;
}
