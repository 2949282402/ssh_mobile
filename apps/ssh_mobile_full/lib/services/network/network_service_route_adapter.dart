part of 'network_service.dart';

/// Route 查询适配器：只读取 state projection，不触碰命令或 Runtime Owner。
final class _NetworkRouteAdapter {
  _NetworkRouteAdapter({required this.commands, required this.projection});

  final _NetworkCommandCoordinator commands;
  final _NetworkStateProjection projection;

  Future<NetworkResult<RouteSnapshot>> state(String peerId) async {
    commands.ensureUsable();
    if (peerId.trim().isEmpty) {
      return _networkFailure(
        const NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'peer_id is required',
          operation: NetworkOperation.state,
        ),
      );
    }
    final route = projection.routeFor(peerId);
    if (route == null) {
      return _networkFailure(
        NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'peer route is not available',
          operation: NetworkOperation.state,
          peerId: peerId,
        ),
      );
    }
    return NetworkSuccess<RouteSnapshot>(route);
  }
}
