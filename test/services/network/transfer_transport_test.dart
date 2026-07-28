import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/network/transfer_transport.dart';
import 'package:ssh_mobile/services/network/network_route_service.dart';

void main() {
  group('TransferTransport and Route Diagnostics Tests', () {
    test('RouteSnapshot formatting and NetworkRouteService updates', () async {
      final routeService = NetworkRouteService();
      final snapshot = RouteSnapshot(
        peerId: 'peer-1',
        connectionKind: RouteConnectionKind.direct,
        protocolKind: RouteProtocolKind.quic,
        endpointAddress: '2001:db8::1:4433',
        rttMs: 26,
        lossRate: 0.001,
        lastUpdated: DateTime.now(),
      );

      routeService.updateRoute(snapshot);

      final fetched = routeService.getRoute('peer-1');
      expect(fetched, isNotNull);
      expect(fetched!.connectionKind, equals(RouteConnectionKind.direct));
      expect(fetched.rttMs, equals(26));
      expect(fetched.formattedSummary, contains('Direct (QUIC)'));
      expect(fetched.formattedSummary, contains('26 ms'));

      routeService.dispose();
    });

    test('TransferSession model creation', () {
      final session = TransferSession(
        transferId: 't-123',
        peerId: 'peer-1',
        filePath: '/tmp/test.txt',
        transport: TransportKind.quicDirect,
      );

      expect(session.transferId, equals('t-123'));
      expect(session.transport, equals(TransportKind.quicDirect));
    });
  });
}
