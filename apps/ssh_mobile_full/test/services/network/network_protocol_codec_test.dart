// 手写 Dart 网络编解码器的固定字节 v1 golden 测试。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/app/network_v1_adapters.dart';

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
    expect(event, isA<TransferFailed>());
    final failure = event! as TransferFailed;
    expect(failure.transferId, 't');
    expect(failure.error.code, NetworkErrorCode.noRoute);
    expect(failure.error.operation, NetworkOperation.send);
    expect(failure.error.peerId, 'p1');
  });

  test('incoming offer accepts optional Relay route metadata', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x01, // protocol_version = 1
        0x72, 0x0d, // incoming offer message
        0x0a, 0x01, 0x74, // transfer_id = t
        0x12, 0x01, 0x70, // peer_id = p
        0x1a, 0x01, 0x66, // file_name = f
        0x20, 0x03, // file_size = 3
        0x28, 0x02, // route_type = Relay
      ]),
    );

    expect(frame.event, isA<IncomingTransferOffer>());
    expect(
      (frame.event! as IncomingTransferOffer).routeType,
      NetworkRouteType.relay,
    );
  });

  test('peer and route events decode composed topology and transport', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x01, // protocol_version = 1
        0x52, 0x0b, // peer state message
        0x0a, 0x01, 0x70, // peer_id = p
        0x10, 0x02, // connected
        0x18, 0x00, // legacy flat route = unspecified
        0x28, 0x01, // topology = direct
        0x30, 0x02, // transport = tcp
      ]),
    );
    final event = frame.event! as PeerStateChanged;
    expect(event.routeType, NetworkRouteType.unspecified);
    expect(event.routeTopology, NetworkRouteTopology.direct);
    expect(event.routeTransport, NetworkRouteTransport.tcp);
  });
}
