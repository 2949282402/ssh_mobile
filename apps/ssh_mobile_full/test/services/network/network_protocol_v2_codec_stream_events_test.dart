// Network Protocol V2 ReliableStream event and malformed-input tests.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

import 'network_protocol_v2_codec_test_utils.dart';

void main() {
  const codec = NetworkProtocolV2Codec();

  test('ssh stream data received event decodes from tag 26', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x03, 0x65, 0x76, 0x74, // event_id = evt
        0x18, 0x02, // protocol_version = 2
        0xd2, 0x01, 0x1c, // field 26 key + length 28
        0x0a, 0x06, 0x70, 0x65, 0x65, 0x72, 0x2d, 0x61, // peer_id = peer-a
        0x12, 0x0c, // handle
        0x0a,
        0x08,
        0x64,
        0x65,
        0x76,
        0x69,
        0x63,
        0x65,
        0x2d,
        0x61, // opener_device_id = device-a
        0x10, 0x07, // stream_id = 7
        0x1a, 0x04, 0x01, 0x02, 0x03, 0x04, // data
      ]),
    );

    expect(frame.sshStreamData, isNotNull);
    expect(frame.event, isNull);
    final stream = frame.sshStreamData!;
    expect(stream.peerId, 'peer-a');
    expect(
      stream.handle,
      const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
    );
    expect(stream.data, orderedEquals(<int>[1, 2, 3, 4]));
  });

  test('ssh stream closed event decodes from tag 27', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x03, 0x65, 0x76, 0x74, // event_id = evt
        0x18, 0x02, // protocol_version = 2
        0xda, 0x01, 0x16, // field 27 key + length 22
        0x0a, 0x06, 0x70, 0x65, 0x65, 0x72, 0x2d, 0x61, // peer_id = peer-a
        0x12,
        0x0c, // handle
        0x0a,
        0x08,
        0x64,
        0x65,
        0x76,
        0x69,
        0x63,
        0x65,
        0x2d,
        0x61, // opener_device_id = device-a
        0x10, 0x07, // stream_id = 7
      ]),
    );

    expect(frame.sshStreamClosed, isNotNull);
    final closed = frame.sshStreamClosed!;
    expect(closed.peerId, 'peer-a');
    expect(
      closed.handle,
      const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
    );
  });

  test('malformed protobuf and stream handles fail closed at the boundary', () {
    expect(
      () => codec.commandId(Uint8List(0)),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x0a])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x12, 0x00])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x08, 0x01])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x0a, 0x05, 0x01])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x0b])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x80])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(List<int>.filled(10, 0x80))),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x09, 0x01])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => codec.decodeEvent(Uint8List.fromList(<int>[0x0d, 0x01])),
      throwsA(isA<FormatException>()),
    );

    final missingHandle = codecFrame(26, <int>[
      ...bytesField(1, <int>[0x70, 0x65, 0x65, 0x72, 0x2d, 0x61]),
    ]);
    expect(
      () => codec.decodeEvent(Uint8List.fromList(missingHandle)),
      throwsA(isA<FormatException>()),
    );

    final invalidHandle = codecFrame(27, <int>[
      ...bytesField(1, <int>[0x70, 0x65, 0x65, 0x72, 0x2d, 0x61]),
      ...bytesField(2, <int>[...bytesField(1, <int>[]), ...varintField(2, 0)]),
    ]);
    expect(
      () => codec.decodeEvent(Uint8List.fromList(invalidHandle)),
      throwsA(isA<FormatException>()),
    );
  });
}
