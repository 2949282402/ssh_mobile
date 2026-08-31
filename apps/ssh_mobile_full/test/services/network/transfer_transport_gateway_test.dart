// Network Protocol V2 gateway facade and command-trace tests.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';
import 'package:ssh_mobile/services/network/network_service.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'transfer_transport_test_support.dart';

void main() {
  group('NetworkService V2 gateway contract tests', () {
    test(
      'gateway facade covers invalid input, status mapping, and lifecycle',
      () async {
        final statusCases = <(TransportOperationStatus, NetworkErrorCode)>[
          (
            TransportOperationStatus.invalidArgument,
            NetworkErrorCode.invalidArgument,
          ),
          (TransportOperationStatus.stopped, NetworkErrorCode.cancelled),
          (TransportOperationStatus.failure, NetworkErrorCode.ioError),
        ];
        for (final (status, expectedCode) in statusCases) {
          final gateway = TransferFakeCommandGateway(status: status);
          final service = NativeNetworkService.fromGateway(gateway);
          final result = await service.disconnect('peer-a');
          expect(result, isA<NetworkFailure<void>>());
          expect((result as NetworkFailure<void>).error.code, expectedCode);
          await service.dispose();
          await gateway.close();
        }

        final gateway = TransferFakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        expect(
          (await service.connect('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.disconnect('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.cancel('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.send(
            transferId: '',
            peerId: 'peer-a',
            filePath: '/missing/payload.bin',
          )).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.send(
            transferId: 'transfer-a',
            peerId: 'peer-a',
            filePath: '/missing/payload.bin',
          )).errorCode,
          NetworkErrorCode.ioError,
        );
        expect(
          (await service.state('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect(
          (await service.state('peer-a')).errorCode,
          NetworkErrorCode.noRoute,
        );

        final root = await Directory.systemTemp.createTemp(
          'ssh-mobile-gateway-',
        );
        addTearDown(() => root.delete(recursive: true));
        final startConfig = NetworkRuntimeConfig(
          deviceId: 'gateway-device',
          identityPrivateKey: Uint8List.fromList(List.filled(32, 1)),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 2)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: root.path,
        );
        expect((await service.start(startConfig)).isSuccess, isTrue);
        expect((await service.start(startConfig)).isSuccess, isTrue);
        expect((await service.disconnect('peer-a')).isSuccess, isTrue);

        final routeFrame = transferEventFrame(17, <int>[
          ...transferBytesField(1, utf8.encode('peer-a')),
          ...transferVarintField(2, NetworkRouteType.relay.wireValue),
          ...transferBytesField(3, utf8.encode('relay.example.test:443')),
        ]);
        gateway.emit(routeFrame);
        await Future<void>.delayed(Duration.zero);
        final route = await service.state('peer-a');
        expect(route, isA<NetworkSuccess<RouteSnapshot>>());
        expect(
          (route as NetworkSuccess<RouteSnapshot>).data.routeType,
          NetworkRouteType.relay,
        );
        expect((await service.connect('peer-a')).isSuccess, isTrue);

        expect(
          (await service.removePeer('')).errorCode,
          NetworkErrorCode.invalidArgument,
        );
        expect((await service.removePeer('peer-a')).isSuccess, isTrue);

        final configureRelayFuture = service.configureRelay(
          RelayConfig(
            relayUrl: 'wss://relay.example.test/ws',
            relayCredential: 'credential',
            relaySigningSeed: Uint8List.fromList(<int>[1, 2, 3]),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          transferEventFrame(18, <int>[
            ...transferVarintField(1, RelayConnectionState.connected.wireValue),
          ]),
        );
        expect((await configureRelayFuture).isSuccess, isTrue);
        expect((await service.disconnectRelay()).isSuccess, isTrue);
        expect((await service.stop()).isSuccess, isTrue);
        expect((await service.stop()).isSuccess, isTrue);
        expect(
          (await service.cancel('transfer-a')).errorCode,
          NetworkErrorCode.cancelled,
        );
      },
    );

    test(
      'relay failure invalidates relay routes and publishes peer disconnect',
      () async {
        final gateway = TransferFakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        gateway.emit(
          transferEventFrame(17, <int>[
            ...transferBytesField(1, utf8.encode('peer-relay')),
            ...transferVarintField(2, NetworkRouteType.relay.wireValue),
            ...transferBytesField(3, utf8.encode('relay.example.test:443')),
          ]),
        );
        await Future<void>.delayed(Duration.zero);
        final route = await service.state('peer-relay');
        expect(route, isA<NetworkSuccess<RouteSnapshot>>());
        expect(
          (route as NetworkSuccess<RouteSnapshot>).data.routeType,
          NetworkRouteType.relay,
        );

        final disconnectedFuture = firstPeerEvent(
          service,
          (event) =>
              event.peerId == 'peer-relay' &&
              event.state == PeerConnectionState.disconnected,
        );
        gateway.emit(
          transferEventFrame(18, <int>[
            ...transferVarintField(1, RelayConnectionState.failed.wireValue),
            ...transferBytesField(2, <int>[
              ...transferVarintField(1, NetworkErrorCode.relayError.wireValue),
              ...transferBytesField(2, utf8.encode('relay unavailable')),
            ]),
          ]),
        );

        final disconnected = await disconnectedFuture.timeout(
          const Duration(seconds: 1),
        );
        expect(disconnected.routeType, NetworkRouteType.unspecified);
        expect(disconnected.error?.code, NetworkErrorCode.relayError);
        expect(
          (await service.state('peer-relay')).errorCode,
          NetworkErrorCode.noRoute,
        );
      },
    );

    test(
      'gateway events drive failed peer and relay terminal states',
      () async {
        final gateway = TransferFakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        final connectFuture = service.connect('peer-failed');
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          transferEventFrame(10, <int>[
            ...transferBytesField(1, utf8.encode('peer-failed')),
            ...transferVarintField(2, PeerConnectionState.failed.wireValue),
            ...transferBytesField(4, <int>[
              ...transferVarintField(1, NetworkErrorCode.noRoute.wireValue),
              ...transferBytesField(2, utf8.encode('route unavailable')),
            ]),
          ]),
        );
        final connectResult = await connectFuture;
        expect(connectResult.errorCode, NetworkErrorCode.noRoute);

        final relayFuture = service.configureRelay(
          RelayConfig(
            relayUrl: 'wss://relay.example.test/ws',
            relayCredential: 'credential',
            relaySigningSeed: Uint8List.fromList(<int>[4, 5, 6]),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          transferEventFrame(18, <int>[
            ...transferVarintField(1, RelayConnectionState.failed.wireValue),
            ...transferBytesField(2, <int>[
              ...transferVarintField(1, NetworkErrorCode.relayError.wireValue),
              ...transferBytesField(2, utf8.encode('relay unavailable')),
            ]),
          ]),
        );
        final relayResult = await relayFuture;
        expect(relayResult.errorCode, NetworkErrorCode.relayError);
      },
    );

    test(
      'connect command inherits and releases the SSH operation trace',
      () async {
        final gateway = TransferFakeCommandGateway();
        final traces = TelemetryTraceRegistry();
        traces.bindPeer(peerId: 'peer-traced', traceId: 'trace-operation');
        final service = NativeNetworkService.fromGateway(
          gateway,
          traceRegistry: traces,
        );
        addTearDown(() async {
          await service.dispose();
          traces.dispose();
          await gateway.close();
        });

        final connectFuture = service.connect('peer-traced');
        await Future<void>.delayed(Duration.zero);
        final commandId = const NetworkProtocolV2Codec().commandId(
          gateway.commands.single,
        );
        expect(traces.traceForCommand(commandId), 'trace-operation');

        gateway.emit(
          transferEventFrame(10, <int>[
            ...transferBytesField(1, utf8.encode('peer-traced')),
            ...transferVarintField(2, PeerConnectionState.connected.wireValue),
            ...transferVarintField(3, NetworkRouteType.quicDirect.wireValue),
          ]),
        );
        expect((await connectFuture).isSuccess, isTrue);
        expect(traces.traceForCommand(commandId), isNull);
        // The adapter's terminal boundary releases the peer and its command;
        // a bridge borrower may independently observe the same event without
        // owning or extending this registry lifecycle.
        expect(traces.traceForPeer('peer-traced'), isNull);
      },
    );
  });
}
