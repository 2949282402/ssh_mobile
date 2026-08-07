// 手写 Dart 网络编解码器的固定字节 v1 golden 测试。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/network/network_models.dart';
import 'package:ssh_mobile/services/network/network_protocol_codec.dart';

/// 执行固定字节 v1 编解码和类型化事件往返测试。
void main() {
  const codec = NetworkProtocolCodec();

  test('disconnect relay command matches the v1 golden bytes', () {
    final bytes = codec.disconnectRelayCommand(commandId: 'c');
    expect(bytes, <int>[0x0a, 0x01, 0x63, 0x10, 0x01, 0x92, 0x01, 0x00]);
    expect(codec.commandId(bytes), 'c');
  });

  test('command result event decodes from fixed v1 bytes', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e，事件标识。
        0x10, 0x64, // timestamp_ms = 100，时间戳。
        0x18, 0x01, // protocol_version = 1，协议版本。
        0x6a, 0x05, // command_result message，命令结果消息。
        0x0a, 0x01, 0x63, // command_id = c，命令标识。
        0x10, 0x01, // accepted = true，命令已接受。
      ]),
    );

    expect(frame.eventId, 'e');
    expect(frame.protocolVersion, 1);
    expect(frame.commandId, 'c');
    expect(frame.commandAccepted, isTrue);
    expect(frame.event, isNull);
  });

  test('typed transfer failure preserves stable error context', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a,
        0x01,
        0x66,
        0x18,
        0x01,
        0x82,
        0x01,
        0x13,
        0x0a,
        0x01,
        0x74,
        0x12,
        0x0e,
        0x08,
        0x03,
        0x12,
        0x00,
        0x1a,
        0x04,
        0x73,
        0x65,
        0x6e,
        0x64,
        0x22,
        0x02,
        0x70,
        0x31,
      ]),
    );
    final event = frame.event;
    expect(event, isA<TransferFailedEvent>());
    final failure = event! as TransferFailedEvent;
    expect(failure.transferId, 't');
    expect(failure.error.code, NetworkErrorCode.noRoute);
    expect(failure.error.operation, NetworkOperation.send);
    expect(failure.error.peerId, 'p1');
  });
}
