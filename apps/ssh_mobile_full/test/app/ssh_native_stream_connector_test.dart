// AppSshNativeStreamConnector 单元测试：验证 native SSH 流命令发送与事件路由。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:ssh_mobile/app/ssh_native_stream_adapters.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

void main() {
  group('AppSshNativeStreamConnector', () {
    test(
      'open queues SshStreamOpen and routes data/closed events by stream id',
      () async {
        final gateway = _FakeGateway();
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

        // 推送 SshStreamDataReceived（tag 26）。
        gateway.push(
          _dataFrame(
            eventId: 'e1-ambiguous',
            peerId: 'peer-a',
            openerDeviceId: 'device-b',
            streamId: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(received, isEmpty);

        gateway.push(
          _dataFrame(
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
          _closedFrame(
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
        final gateway = _FakeGateway();
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
      final gateway = _FakeGateway();
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
        final gateway = _FakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
          openerDeviceIdProvider: () async => 'device-a',
        );
        final stream = await connector.open(peerId: 'peer-a');
        expect(connector.activeStreamCount, 1);
        final openCommandId = _commandIdOf(gateway.commands.first);

        final errors = <Object>[];
        final doneErrors = <Object>[];
        stream.done.then((_) {}, onError: doneErrors.add);
        final incomingSubscription = stream.incoming.listen(
          (_) {},
          onError: (Object error, StackTrace _) => errors.add(error),
        );

        // native 以 CommandResult accepted=false 拒绝 SshStreamOpen。
        gateway.push(
          _commandResultFrame(
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
        final gateway = _FakeGateway();
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
        final openCommandId = _commandIdOf(gateway.commands.first);
        expect(traces.traceForCommand(openCommandId), 'trace-operation');

        gateway.push(
          _commandResultFrame(
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
          _dataFrame(
            eventId: 'e4',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(1));

        gateway.push(
          _closedFrame(
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
        final gateway = _FakeGateway();
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

    test(
      'late opener completion cannot register a stream after closeAll',
      () async {
        final opener = Completer<String>();
        final gateway = _FakeGateway();
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
        final gateway = _FakeGateway();
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
      final gateway = _FakeGateway();
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
      final gateway = _FakeGateway();
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
        final gateway = _FakeGateway();
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
        final gateway = _FakeGateway();
        final connectResult = Completer<SdkResult<void>>();
        final facade = _RecordingNetworkFacade(() {
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
      'wraps stream IDs, skips occupied handles, and fails when exhausted',
      () async {
        final gateway = _FakeGateway();
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
          _dataFrame(
            eventId: 'wrapped-first',
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ),
        );
        gateway.push(
          _dataFrame(
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

/// 构建 SshStreamDataReceived 事件帧（tag 26）。
Uint8List _dataFrame({
  required String eventId,
  required String peerId,
  required String openerDeviceId,
  required int streamId,
}) {
  final payload = <int>[
    ..._stringField(1, peerId),
    ..._messageField(2, <int>[
      ..._stringField(1, openerDeviceId),
      ..._varintField(2, streamId),
    ]),
    0x1a,
    0x03,
    0x01,
    0x02,
    0x03,
  ];
  return _eventFrame(eventId, 26, payload);
}

/// 构建 CommandResult 事件帧（tag 13）。
Uint8List _commandResultFrame({
  required String eventId,
  required String commandId,
  required bool accepted,
  String? errorMessage,
}) {
  final payload = <int>[
    ..._stringField(1, commandId),
    ..._varintField(2, accepted ? 1 : 0),
    if (errorMessage != null)
      ..._messageField(3, _networkErrorField(7, errorMessage)),
  ];
  return _eventFrame(eventId, 13, payload);
}

/// 编码一个嵌套 message 字段（wire type 2）。
List<int> _messageField(int field, List<int> payload) => <int>[
  ..._varint(field << 3 | 2),
  ..._varint(payload.length),
  ...payload,
];

/// 编码一个 NetworkError 子消息：code(1) + message(2)。
List<int> _networkErrorField(int code, String message) => <int>[
  ..._varintField(1, code),
  ..._stringField(2, message),
];

/// 从命令信封读取 command_id（field 1 字符串）。
String _commandIdOf(Uint8List command) {
  var offset = 0;
  int readVarint() {
    var value = 0;
    var shift = 0;
    while (true) {
      final byte = command[offset++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return value;
      shift += 7;
    }
  }

  final key = readVarint();
  if (key >> 3 != 1) {
    throw StateError('expected command_id field (1)');
  }
  final length = readVarint();
  return String.fromCharCodes(command.sublist(offset, offset + length));
}

/// 构建 SshStreamClosed 事件帧（tag 27）。
Uint8List _closedFrame({
  required String eventId,
  required String peerId,
  required String openerDeviceId,
  required int streamId,
}) {
  final payload = <int>[
    ..._stringField(1, peerId),
    ..._messageField(2, <int>[
      ..._stringField(1, openerDeviceId),
      ..._varintField(2, streamId),
    ]),
  ];
  return _eventFrame(eventId, 27, payload);
}

Uint8List _eventFrame(String eventId, int field, List<int> payload) {
  final bytes = <int>[
    ..._stringField(1, eventId),
    0x10,
    0x01, // timestamp_ms = 1
    0x18,
    0x02, // protocol_version = 2
    ..._varint(field << 3 | 2),
    ..._varint(payload.length),
    ...payload,
  ];
  return Uint8List.fromList(bytes);
}

List<int> _stringField(int field, String value) {
  final encoded = value.codeUnits;
  return <int>[
    ..._varint(field << 3 | 2),
    ..._varint(encoded.length),
    ...encoded,
  ];
}

/// 编码一个 varint 字段：key（wire type 0）+ value。
List<int> _varintField(int field, int value) => <int>[
  ..._varint(field << 3),
  ..._varint(value),
];

List<int> _varint(int value) {
  final out = <int>[];
  var remaining = value;
  while (remaining >= 0x80) {
    out.add((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  out.add(remaining);
  return out;
}

final class _FakeGateway implements NetworkCommandGateway {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> commands = <Uint8List>[];

  /// 可配置的 sendCommand 返回结果；默认成功，测试失败路径时改为非 success。
  TransportOperationStatus sendResult = TransportOperationStatus.success;

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    commands.add(command);
    return sendResult;
  }

  void push(Uint8List frame) => _events.add(frame);
}

final class _RecordingNetworkFacade extends Fake implements NetworkFacade {
  _RecordingNetworkFacade(this._connect);

  final Future<SdkResult<void>> Function() _connect;
  int connectCalls = 0;

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) {
    connectCalls++;
    return _connect();
  }
}
