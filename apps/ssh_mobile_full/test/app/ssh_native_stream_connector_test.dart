// AppSshNativeStreamConnector 单元测试：验证 native SSH 流命令发送与事件路由。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/ssh_native_stream_adapters.dart';

void main() {
  group('AppSshNativeStreamConnector', () {
    test(
      'open queues SshStreamOpen and routes data/closed events by stream id',
      () async {
        final gateway = _FakeGateway();
        final connector = AppSshNativeStreamConnector(
          gatewayProvider: () async => gateway,
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
        gateway.push(_dataFrame(eventId: 'e1', peerId: 'peer-a', streamId: 1));
        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(1));
        expect(received[0], orderedEquals([0x01, 0x02, 0x03]));

        // 推送 SshStreamClosed（tag 27），done 完成且流被移除。
        gateway.push(
          _closedFrame(eventId: 'e2', peerId: 'peer-a', streamId: 1),
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
      );
      final stream = await connector.open(peerId: 'peer-a');
      final doneFuture = stream.done.then((_) {});

      await connector.closeAll();
      expect(connector.activeStreamCount, 0);
      await doneFuture;

      // 再次 closeAll 幂等。
      await connector.closeAll();
    });
  });
}

/// 构建 SshStreamDataReceived 事件帧（tag 26）。
Uint8List _dataFrame({
  required String eventId,
  required String peerId,
  required int streamId,
}) {
  final payload = <int>[
    ..._stringField(1, peerId),
    ..._varintField(2, streamId),
    0x1a,
    0x03,
    0x01,
    0x02,
    0x03,
  ];
  return _eventFrame(eventId, 26, payload);
}

/// 构建 SshStreamClosed 事件帧（tag 27）。
Uint8List _closedFrame({
  required String eventId,
  required String peerId,
  required int streamId,
}) {
  final payload = <int>[
    ..._stringField(1, peerId),
    ..._varintField(2, streamId),
  ];
  return _eventFrame(eventId, 27, payload);
}

Uint8List _eventFrame(String eventId, int field, List<int> payload) {
  final bytes = <int>[
    ..._stringField(1, eventId),
    0x10,
    0x01, // timestamp_ms = 1
    0x18,
    0x01, // protocol_version = 1
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

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    commands.add(command);
    return TransportOperationStatus.success;
  }

  void push(Uint8List frame) => _events.add(frame);
}
