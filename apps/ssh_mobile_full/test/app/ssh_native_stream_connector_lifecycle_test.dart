// AppSshNativeStreamConnector lifecycle, trace, and handle-allocation tests.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile/app/ssh_native_stream_adapters.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'ssh_native_stream_connector_test_support.dart';

void main() {
  group('AppSshNativeStreamConnector lifecycle', () {
    test(
      'late opener completion cannot register a stream after closeAll',
      () async {
        final opener = Completer<String>();
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () => opener.future,
        );

        final openFuture = connector.open(peerId: 'peer-a');
        final expectation = expectLater(openFuture, throwsA(isA<StateError>()));
        await Future<void>.delayed(Duration.zero);
        await connector.closeAll();
        opener.complete('device-a');

        await expectation;
        expect(connector.activeStreamCount, 0);
        expect(gateway.commands, isEmpty);
      },
    );

    test(
      'late gateway completion cannot register a stream after closeAll',
      () async {
        final gatewayFuture = Completer<NetworkCommandGateway>();
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () => gatewayFuture.future,
          openerDeviceIdProvider: () async => 'device-a',
        );

        final openFuture = connector.open(peerId: 'peer-a');
        final expectation = expectLater(openFuture, throwsA(isA<StateError>()));
        await Future<void>.delayed(Duration.zero);
        await connector.closeAll();
        gatewayFuture.complete(gateway);

        await expectation;
        expect(connector.activeStreamCount, 0);
        expect(gateway.commands, isEmpty);
      },
    );

    test('failed opener identity lookup can be retried', () async {
      final gateway = StreamFakeGateway();
      var attempts = 0;
      final connector = AppSshNativeStreamConnector(
        gatewayProvider: () async => gateway,
        openerDeviceIdProvider: () async {
          attempts++;
          if (attempts == 1) {
            throw StateError('identity temporarily unavailable');
          }
          return 'device-a';
        },
      );

      await expectLater(connector.open(peerId: 'peer-a'), throwsStateError);
      final stream = await connector.open(peerId: 'peer-a');

      expect(attempts, 2);
      expect(connector.activeStreamCount, 1);
      await stream.close();
      await connector.closeAll();
    });

    test('send throws after the connector is closed', () async {
      final gateway = StreamFakeGateway();
      final connector = AppSshNativeStreamConnector(
        gatewayProvider: () async => gateway,
        openerDeviceIdProvider: () async => 'device-a',
      );
      final stream = await connector.open(peerId: 'peer-a');

      await connector.closeAll();

      await expectLater(
        stream.send(Uint8List.fromList([0xde, 0xad])),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'fails closed when the lazily supplied native facade is unavailable',
      () async {
        final gateway = StreamFakeGateway();
        final traces = TelemetryTraceRegistry();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
          facadeProvider: () => null,
          traceRegistry: traces,
        );

        await expectLater(
          connector.open(peerId: 'peer-a', traceId: 'trace-operation'),
          throwsA(isA<StateError>()),
        );
        expect(gateway.commands, isEmpty);
        expect(traces.traceForPeer('peer-a'), isNull);
        await connector.closeAll();
        traces.dispose();
      },
    );

    test(
      'coalesces concurrent peer connects and retains the SSH operation trace',
      () async {
        final gateway = StreamFakeGateway();
        final connectResult = Completer<SdkResult<void>>();
        final facade = StreamRecordingNetworkFacade(() {
          return connectResult.future;
        });
        final traces = TelemetryTraceRegistry();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
          facade: facade,
          traceRegistry: traces,
        );

        final firstOpen = connector.open(
          peerId: 'peer-a',
          traceId: 'trace-operation',
        );
        while (facade.connectCalls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        final secondOpen = connector.open(
          peerId: 'peer-a',
          traceId: 'trace-collision',
        );
        connectResult.complete(const SdkSuccess<void>(null));

        final streams = await Future.wait(<Future<SshNativeStream>>[
          firstOpen,
          secondOpen,
        ]);
        expect(streams, hasLength(2));
        expect(facade.connectCalls, 1);
        expect(traces.traceForPeer('peer-a'), 'trace-operation');

        await connector.closeAll();
        expect(traces.traceForPeer('peer-a'), isNull);
        traces.dispose();
      },
    );

    test(
      'releases the peer trace when the final stream reaches its terminal boundary',
      () async {
        final gateway = StreamFakeGateway();
        final traces = TelemetryTraceRegistry();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
          facade: StreamRecordingNetworkFacade(() async {
            return const SdkSuccess<void>(null);
          }),
          traceRegistry: traces,
        );
        addTearDown(() async {
          await connector.closeAll();
          traces.dispose();
        });

        final stream = await connector.open(
          peerId: 'peer-a',
          traceId: 'trace-operation',
        );
        final openCommandId = streamCommandIdOf(gateway.commands.last);
        gateway.push(
          streamCommandResultFrame(
            eventId: 'terminal-accepted',
            commandId: openCommandId,
            accepted: true,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(traces.traceForPeer('peer-a'), 'trace-operation');

        await stream.close();

        expect(connector.activeStreamCount, 0);
        expect(traces.traceForPeer('peer-a'), isNull);
        expect(traces.peerBindingCount, 0);
        expect(traces.commandBindingCount, 0);
      },
    );

    test(
      'wraps stream IDs, skips occupied handles, and fails when exhausted',
      () async {
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
        );

        final firstStream = await connector.open(peerId: 'peer-a');
        final occupiedSecondStream = await connector.open(peerId: 'peer-a');
        for (var streamId = 3; streamId <= 0xffff; streamId++) {
          await connector.open(peerId: 'peer-a');
        }
        expect(connector.activeStreamCount, 0xffff);

        await expectLater(
          connector.open(peerId: 'peer-a'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('namespace is exhausted'),
            ),
          ),
        );

        await occupiedSecondStream.close();
        final wrappedStream = await connector.open(peerId: 'peer-a');
        expect(connector.activeStreamCount, 0xffff);

        final firstData = <Uint8List>[];
        final wrappedData = <Uint8List>[];
        final firstSubscription = firstStream.incoming.listen(firstData.add);
        final wrappedSubscription = wrappedStream.incoming.listen(
          wrappedData.add,
        );
        gateway.push(
          streamDataFrame(
            eventId: 'wrapped-first',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ),
        );
        gateway.push(
          streamDataFrame(
            eventId: 'wrapped-second',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 2,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(firstData, hasLength(1));
        expect(wrappedData, hasLength(1));

        await firstSubscription.cancel();
        await wrappedSubscription.cancel();
        await connector.closeAll();
      },
    );
  });
}
