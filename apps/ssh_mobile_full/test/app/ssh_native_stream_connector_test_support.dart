import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';

final class StreamFakeGateway implements NetworkCommandGateway {
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

final class StreamRecordingNetworkFacade extends Fake implements NetworkFacade {
  StreamRecordingNetworkFacade(this._connect);

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

/// 构建 SshStreamDataReceived 事件帧（tag 26）。
Uint8List streamDataFrame({
  required String eventId,
  required String peerId,
  required String openerDeviceId,
  required int streamId,
}) {
  final payload = <int>[
    ...streamStringField(1, peerId),
    ...streamMessageField(2, <int>[
      ...streamStringField(1, openerDeviceId),
      ...streamVarintField(2, streamId),
    ]),
    0x1a,
    0x03,
    0x01,
    0x02,
    0x03,
  ];
  return streamEventFrame(eventId, 26, payload);
}

/// 构建 CommandResult 事件帧（tag 13）。
Uint8List streamCommandResultFrame({
  required String eventId,
  required String commandId,
  required bool accepted,
  String? errorMessage,
}) {
  final payload = <int>[
    ...streamStringField(1, commandId),
    ...streamVarintField(2, accepted ? 1 : 0),
    if (errorMessage != null)
      ...streamMessageField(3, streamNetworkErrorField(7, errorMessage)),
  ];
  return streamEventFrame(eventId, 13, payload);
}

/// 编码一个嵌套 message 字段（wire type 2）。
List<int> streamMessageField(int field, List<int> payload) => <int>[
  ...streamVarint(field << 3 | 2),
  ...streamVarint(payload.length),
  ...payload,
];

/// 编码一个 NetworkError 子消息：code(1) + message(2)。
List<int> streamNetworkErrorField(int code, String message) => <int>[
  ...streamVarintField(1, code),
  ...streamStringField(2, message),
];

/// 从命令信封读取 command_id（field 1 字符串）。
String streamCommandIdOf(Uint8List command) {
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
Uint8List streamClosedFrame({
  required String eventId,
  required String peerId,
  required String openerDeviceId,
  required int streamId,
}) {
  final payload = <int>[
    ...streamStringField(1, peerId),
    ...streamMessageField(2, <int>[
      ...streamStringField(1, openerDeviceId),
      ...streamVarintField(2, streamId),
    ]),
  ];
  return streamEventFrame(eventId, 27, payload);
}

Uint8List streamEventFrame(String eventId, int field, List<int> payload) {
  final bytes = <int>[
    ...streamStringField(1, eventId),
    0x10,
    0x01, // timestamp_ms = 1
    0x18,
    0x02, // protocol_version = 2
    ...streamVarint(field << 3 | 2),
    ...streamVarint(payload.length),
    ...payload,
  ];
  return Uint8List.fromList(bytes);
}

List<int> streamStringField(int field, String value) {
  final encoded = value.codeUnits;
  return <int>[
    ...streamVarint(field << 3 | 2),
    ...streamVarint(encoded.length),
    ...encoded,
  ];
}

/// 编码一个 varint 字段：key（wire type 0）+ value。
List<int> streamVarintField(int field, int value) => <int>[
  ...streamVarint(field << 3),
  ...streamVarint(value),
];

List<int> streamVarint(int value) {
  final out = <int>[];
  var remaining = value;
  while (remaining >= 0x80) {
    out.add((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  out.add(remaining);
  return out;
}
