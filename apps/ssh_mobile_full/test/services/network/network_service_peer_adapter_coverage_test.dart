import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/services/network/network_service.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'transfer_transport_test_support.dart';

void main() {
  group('NetworkService peer adapter behavior', () {
    test(
      'upsertPeer sends a typed peer configuration and awaits acceptance',
      () async {
        final gateway = TransferFakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        final result = await service.upsertPeer(
          PeerConfig(
            peerId: 'peer-upsert',
            endpointAddress: '127.0.0.1:53317',
            identityPublicKey: Uint8List.fromList(List.filled(32, 1)),
            e2ePublicKey: Uint8List.fromList(List.filled(32, 2)),
            allowDirect: true,
            allowRelay: true,
          ),
        );

        expect(result, isA<NetworkSuccess<void>>());
        expect(gateway.commands, hasLength(1));
      },
    );

    test(
      'connect completes and releases a trace when a route already exists',
      () async {
        final gateway = TransferFakeCommandGateway();
        final traces = TelemetryTraceRegistry();
        final service = NativeNetworkService.fromGateway(
          gateway,
          traceRegistry: traces,
        );
        addTearDown(() async {
          await service.dispose();
          traces.dispose();
          await gateway.close();
        });

        gateway.emit(
          transferEventFrame(17, <int>[
            ...transferBytesField(1, utf8.encode('peer-routed')),
            ...transferVarintField(2, NetworkRouteType.quicDirect.wireValue),
            ...transferBytesField(3, utf8.encode('127.0.0.1:53317')),
          ]),
        );
        await Future<void>.delayed(Duration.zero);
        traces.bindPeer(peerId: 'peer-routed', traceId: 'trace-routed');

        final result = await service.connect('peer-routed');

        expect(result, isA<NetworkSuccess<void>>());
        expect(traces.traceForPeer('peer-routed'), isNull);
        expect(gateway.commands, isEmpty);
      },
    );

    test(
      'connect maps a disconnected terminal event to a no-route failure',
      () async {
        final gateway = TransferFakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        final connectFuture = service.connect('peer-disconnected');
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          transferEventFrame(10, <int>[
            ...transferBytesField(1, utf8.encode('peer-disconnected')),
            ...transferVarintField(
              2,
              PeerConnectionState.disconnected.wireValue,
            ),
          ]),
        );

        final result = await connectFuture;

        expect(result, isA<NetworkFailure<void>>());
        expect(
          (result as NetworkFailure<void>).error.code,
          NetworkErrorCode.noRoute,
        );
        expect(result.errorCode, NetworkErrorCode.noRoute);
      },
    );

    test('connect timeout releases the exact peer trace', () async {
      final gateway = TransferFakeCommandGateway();
      final traces = TelemetryTraceRegistry();
      final service = NativeNetworkService.fromGateway(
        gateway,
        traceRegistry: traces,
      );
      addTearDown(() async {
        await service.dispose();
        traces.dispose();
        await gateway.close();
      });
      traces.bindPeer(peerId: 'peer-timeout', traceId: 'trace-timeout');

      final result = await runZoned<Future<NetworkResult<void>>>(
        () => service.connect('peer-timeout'),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              parent.createTimer(zone, Duration.zero, callback),
        ),
      );

      expect(result, isA<NetworkFailure<void>>());
      expect(result.errorCode, NetworkErrorCode.timeout);
      expect(traces.traceForPeer('peer-timeout'), isNull);
    });
  });
}
