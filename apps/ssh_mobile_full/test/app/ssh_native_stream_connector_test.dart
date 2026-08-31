// AppSshNativeStreamConnector command and event-routing tests.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/ssh_native_stream_adapters.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'ssh_native_stream_connector_test_support.dart';

void main() {
  group('AppSshNativeStreamConnector', () {
    test(
      'open queues SshStreamOpen and routes data/closed events by stream id',
      () async {
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
        );

        final stream = await connector.open(peerId: 'peer-a');
        expect(connector.activeStreamCount, 1);
        expect(gateway.commands, isNotEmpty);
        // 第一条命令必须是 SshStreamOpen（tag 25 key 0xca）。
        expect(gateway.commands.first, contains(0xca));

        final received = <Uint8List>[];
        final subscription = stream.incoming.listen(received.add);
        final done = <Object?>[];
        stream.done.then((_) => done.add('done'));

        // 推送错误 opener 的 SshStreamDataReceived（tag 26）。
        gateway.push(
          streamDataFrame(
            eventId: 'e1-ambiguous',
            peerId: 'peer-a',
            openerDeviceId: 'device-b',
            streamId: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(received, isEmpty);

        gateway.push(
          streamDataFrame(
            eventId: 'e1',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(1));
        expect(received[0], orderedEquals([0x01, 0x02, 0x03]));

        // 推送 SshStreamClosed（tag 27），done 完成且流被移除。
        gateway.push(
          streamClosedFrame(
            eventId: 'e2',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ),
        );
        await stream.done;
        expect(done, ['done']);
        expect(connector.activeStreamCount, 0);

        await subscription.cancel();
        await connector.closeAll();
      },
    );

    test(
      'send and close queue SshStreamData and SshStreamClose commands',
      () async {
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
        );
        final stream = await connector.open(peerId: 'peer-a');
        gateway.commands.clear();

        await stream.send(Uint8List.fromList([0xde, 0xad]));
        expect(gateway.commands, hasLength(1));
        expect(gateway.commands.first, contains(0xd2)); // tag 26 key

        await stream.close();
        expect(gateway.commands, hasLength(2));
        expect(gateway.commands.last, contains(0xda)); // tag 27 key
        expect(connector.activeStreamCount, 0);

        await connector.closeAll();
      },
    );

    test('closeAll aborts all streams and releases the gateway', () async {
      final gateway = StreamFakeGateway();
      final connector = AppSshNativeStreamConnector(
        gatewayProvider: () async => gateway,
        openerDeviceIdProvider: () async => 'device-a',
      );
      final stream = await connector.open(peerId: 'peer-a');
      final doneFuture = stream.done.then((_) {});

      await connector.closeAll();
      expect(connector.activeStreamCount, 0);
      await doneFuture;

      // 再次 closeAll 幂等。
      await connector.closeAll();
    });

    test(
      'rejected SshStreamOpen CommandResult fails the stream instead of hanging',
      () async {
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
        );
        final stream = await connector.open(peerId: 'peer-a');
        expect(connector.activeStreamCount, 1);
        final openCommandId = streamCommandIdOf(gateway.commands.first);

        final errors = <Object>[];
        final doneErrors = <Object>[];
        stream.done.then((_) {}, onError: doneErrors.add);
        final incomingSubscription = stream.incoming.listen(
          (_) {},
          onError: (Object error, StackTrace _) => errors.add(error),
        );

        // native 以 CommandResult accepted=false 拒绝 SshStreamOpen。
        gateway.push(
          streamCommandResultFrame(
            eventId: 'e3',
            commandId: openCommandId,
            accepted: false,
            errorMessage: 'peer is not connected',
          ),
        );

        await expectLater(stream.done, throwsA(isA<StateError>()));
        expect(doneErrors, hasLength(1));
        expect(
          (doneErrors.single as StateError).message,
          contains('peer is not connected'),
        );
        expect(errors, hasLength(1));
        expect(connector.activeStreamCount, 0);

        await incomingSubscription.cancel();
        await connector.closeAll();
      },
    );

    test(
      'accepted SshStreamOpen CommandResult keeps the stream usable',
      () async {
        final gateway = StreamFakeGateway();
        final traces = TelemetryTraceRegistry();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
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
        final openCommandId = streamCommandIdOf(gateway.commands.first);
        expect(traces.traceForCommand(openCommandId), 'trace-operation');

        gateway.push(
          streamCommandResultFrame(
            eventId: 'e3',
            commandId: openCommandId,
            accepted: true,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        // An accepted command remains correlated until the stream's terminal
        // close event, then its command context is gone. A paired peer context
        // follows the same terminal cleanup path when facade mode is enabled.
        expect(traces.traceForCommand(openCommandId), 'trace-operation');
        // 流仍登记：后续数据事件照常路由。
        expect(connector.activeStreamCount, 1);

        final received = <Uint8List>[];
        final subscription = stream.incoming.listen(received.add);
        gateway.push(
          streamDataFrame(
            eventId: 'e4',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(1));

        gateway.push(
          streamClosedFrame(
            eventId: 'e5',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ),
        );
        await stream.done;
        expect(traces.traceForCommand(openCommandId), isNull);

        await subscription.cancel();
      },
    );

    test(
      'send fails the stream when the gateway rejects the data command',
      () async {
        final gateway = StreamFakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
        );
        final stream = await connector.open(peerId: 'peer-a');
        gateway.commands.clear();

        final errors = <Object>[];
        final doneErrors = <Object>[];
        stream.done.then((_) {}, onError: doneErrors.add);
        final incomingSubscription = stream.incoming.listen(
          (_) {},
          onError: (Object error, StackTrace _) => errors.add(error),
        );

        // native 拒绝 SshStreamData：send 必须抛错并让流失败，
        // 而不是静默丢弃字节。
        gateway.sendResult = TransportOperationStatus.failure;

        await expectLater(
          stream.send(Uint8List.fromList([0xde, 0xad])),
          throwsA(isA<StateError>()),
        );
        expect(doneErrors, hasLength(1));
        expect(errors, hasLength(1));
        expect(connector.activeStreamCount, 0);

        await incomingSubscription.cancel();
        await connector.closeAll();
      },
    );
  });
}
