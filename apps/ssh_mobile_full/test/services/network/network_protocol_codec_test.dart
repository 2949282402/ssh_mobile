// 手写 Dart 网络编解码器的固定字节 v1 golden 测试。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import '../../../lib/services/network/network_protocol_codec.dart';

/// 执行固定字节 v1 编解码和类型化事件往返测试。
void main() {
  const codec = NetworkProtocolCodec();

  test('disconnect relay command matches the v1 golden bytes', () {
    final bytes = codec.disconnectRelayCommand(commandId: 'c');
    expect(bytes, <int>[0x0a, 0x01, 0x63, 0x10, 0x01, 0x92, 0x01, 0x00]);
    expect(codec.commandId(bytes), 'c');
  });

  test('connect peer command carries the communication class (field 3)', () {
    final reliableStream = codec.connectPeerCommand(
      commandId: 'c',
      peerId: 'p',
      communicationClass: CommunicationClass.reliableStream,
    );
    // 载荷：peer_id(1)=p、intent(2)=0、communication_class(3)=ReliableStream(1)。
    expect(reliableStream, <int>[
      0x0a, 0x01, 0x63, // command_id = c
      0x10, 0x01, // protocol_version = 1
      0x52, 0x07, // connect peer (field 10), length 7
      0x0a, 0x01, 0x70, // peer_id = p
      0x10, 0x00, // intent = 0
      0x18, 0x01, // communication_class = 1 (ReliableStream)
    ]);
    expect(codec.commandId(reliableStream), 'c');

    final bulk = codec.connectPeerCommand(
      commandId: 'c',
      peerId: 'p',
      communicationClass: CommunicationClass.bulkTransfer,
    );
    expect(bulk, contains(0x18)); // communication_class key
    expect(bulk, contains(0x03)); // BulkTransfer = 3
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

  test('error payload decodes retry disposition and retry-after seconds', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x66, // event_id = f
        0x10, 0x64, // timestamp_ms = 100
        0x18, 0x01, // protocol_version = 1
        0x82, 0x01, 0x14, // transfer failed message (len 20)
        0x0a, 0x01, 0x74, // transfer_id = t
        0x12, 0x0f, // error message (len 15)
        0x08, 0x0c, // code = 12 (credentialExpired)
        0x12, 0x07, 0x65, 0x78, 0x70, 0x69, 0x72, 0x65, 0x64, // 'expired'
        0x28, 0x04, // retry_disposition = 4 (refreshCredentialThenRetry)
        0x30, 0x1e, // retry_after_seconds = 30
      ]),
    );
    final event = frame.event! as TransferFailed;
    expect(event.error.code, NetworkErrorCode.credentialExpired);
    expect(event.error.message, 'expired');
    expect(
      event.error.retryDisposition,
      RetryDisposition.refreshCredentialThenRetry,
    );
    expect(event.error.retryAfterSeconds, 30);
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

  test('peer presence change event decodes from v1 bytes', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x01, // protocol_version = 1
        0xc2, 0x01, 0x07, // field 24 (peer presence change), length 7
        0x0a, 0x01, 0x70, // peer_id = p
        0x10, 0x02, // generation = 2
        0x18, 0x01, // state = online
      ]),
    );
    final event = frame.event! as PeerPresenceChanged;
    expect(event.peerId, 'p');
    expect(event.generation, 2);
    expect(event.state, PeerPresenceState.online);
  });

  test('ssh stream commands encode native tags 25/26/27', () {
    final open = codec.sshStreamOpenCommand(
      commandId: 'open-1',
      peerId: 'peer-a',
      handle: const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
      service: 'ssh',
    );
    expect(open, isNotEmpty);
    expect(open, contains(0xca)); // field 25 key prefix
    expect(open, contains(0x07)); // stream_id = 7

    final data = codec.sshStreamDataCommand(
      commandId: 'data-1',
      peerId: 'peer-a',
      handle: const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
      data: Uint8List.fromList(<int>[0xde, 0xad, 0xbe, 0xef]),
    );
    expect(data, isNotEmpty);
    expect(data, contains(0xd2)); // field 26 key prefix
    expect(data, contains(0xde));
    expect(data, contains(0xef));

    final close = codec.sshStreamCloseCommand(
      commandId: 'close-1',
      peerId: 'peer-a',
      handle: const SshStreamHandle(openerDeviceId: 'device-a', streamId: 7),
    );
    expect(close, isNotEmpty);
    expect(close, contains(0xda)); // field 27 key prefix
  });

  test('ssh stream data received event decodes from tag 26', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x03, 0x65, 0x76, 0x74, // event_id = evt
        0x18, 0x01, // protocol_version = 1
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
        0x18, 0x01, // protocol_version = 1
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

  test('peer presence snapshot event decodes a peer list', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x01, // protocol_version = 1
        0xca, 0x01, 0x12, // field 25 (peer presence snapshot), length 18
        0x0a, 0x07, // peers[0] message, length 7
        0x0a, 0x01, 0x70, // peer_id = p
        0x10, 0x01, // generation = 1
        0x18, 0x01, // state = online
        0x0a, 0x07, // peers[1] message, length 7
        0x0a, 0x01, 0x71, // peer_id = q
        0x10, 0x03, // generation = 3
        0x18, 0x02, // state = updated
      ]),
    );
    final event = frame.event! as PeerPresenceSnapshot;
    expect(event.peers, hasLength(2));
    expect(event.peers.first.peerId, 'p');
    expect(event.peers.first.state, PeerPresenceState.online);
    expect(event.peers.last.peerId, 'q');
    expect(event.peers.last.generation, 3);
    expect(event.peers.last.state, PeerPresenceState.updated);
  });
}
