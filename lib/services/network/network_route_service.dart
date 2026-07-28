import 'dart:async';

enum RouteConnectionKind { direct, relay }

enum RouteProtocolKind { quic, wireguard, https }

class RouteSnapshot {
  final String peerId;
  final RouteConnectionKind connectionKind;
  final RouteProtocolKind protocolKind;
  final String endpointAddress;
  final int rttMs;
  final double lossRate;
  final DateTime lastUpdated;

  RouteSnapshot({
    required this.peerId,
    required this.connectionKind,
    required this.protocolKind,
    required this.endpointAddress,
    required this.rttMs,
    required this.lossRate,
    required this.lastUpdated,
  });

  String get formattedSummary =>
      '${connectionKind == RouteConnectionKind.direct ? "Direct" : "Relay"} '
      '(${protocolKind.name.toUpperCase()}) - $endpointAddress [$rttMs ms, ${(lossRate * 100).toStringAsFixed(1)}% loss]';
}

/// Service managing active peer route snapshots for diagnostics and UI display.
class NetworkRouteService {
  final Map<String, RouteSnapshot> _activeRoutes = {};
  final StreamController<RouteSnapshot> _routeUpdateController =
      StreamController<RouteSnapshot>.broadcast();

  Stream<RouteSnapshot> get routeUpdates => _routeUpdateController.stream;

  void updateRoute(RouteSnapshot snapshot) {
    _activeRoutes[snapshot.peerId] = snapshot;
    _routeUpdateController.add(snapshot);
  }

  RouteSnapshot? getRoute(String peerId) => _activeRoutes[peerId];

  List<RouteSnapshot> get allRoutes => _activeRoutes.values.toList();

  void dispose() {
    _routeUpdateController.close();
  }
}
