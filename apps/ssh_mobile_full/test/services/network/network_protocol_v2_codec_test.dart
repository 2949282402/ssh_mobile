// Network Protocol V2 手写 Dart 编解码器的固定字节 golden 测试。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

/// 执行固定字节 V2 编解码和类型化事件往返测试。
void main() {
  const codec = NetworkProtocolV2Codec();

  test('disconnect relay command matches the V2 golden bytes', () {
    final bytes = codec.disconnectRelayCommand(commandId: 'c');
    expect(bytes, <int>[0x0a, 0x01, 0x63, 0x10, 0x02, 0x92, 0x01, 0x00]);
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
      0x10, 0x02, // protocol_version = 2
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

  test('command result event decodes from fixed V2 bytes', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e，事件标识。
        0x10, 0x64, // timestamp_ms = 100，时间戳。
        0x18, 0x02, // protocol_version = 2，协议版本。
        0x6a, 0x05, // command_result message，命令结果消息。
        0x0a, 0x01, 0x63, // command_id = c，命令标识。
        0x10, 0x01, // accepted = true，命令已接受。
      ]),
    );

    expect(frame.eventId, 'e');
    expect(frame.protocolVersion, 2);
    expect(frame.commandId, 'c');
    expect(frame.commandAccepted, isTrue);
    expect(frame.event, isNull);
  });

  test('typed V2 command result event completes the pending command', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
        0xea, 0x01, 0x0a, // command_result_v2, length 10
        0x0a, 0x01, 0x63, // command_id = c
        0x12, 0x01, 0x70, // peer_id = p
        0x18, 0x01, // state = failed
        0x22, 0x00, // error is optional for the decoder contract
      ]),
    );

    expect(frame.commandId, 'c');
    expect(frame.commandAccepted, isFalse);
    expect(frame.commandError, isNotNull);
  });

  test('typed transfer failure preserves stable error context', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a,
        0x01,
        0x66,
        0x18,
        0x02,
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
        0x18, 0x02, // protocol_version = 2
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
        0x18, 0x02, // protocol_version = 2
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
        0x18, 0x02, // protocol_version = 2
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

  test('peer presence change event decodes from V2 bytes', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
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

  test('peer presence snapshot event decodes a peer list', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
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

  test('control commands encode every V2 command payload boundary', () {
    final commands = <Uint8List>[
      codec.configureRuntimeCommand(
        commandId: 'configure',
        config: NetworkRuntimeConfig(
          deviceId: 'device-a',
          identityPrivateKey: Uint8List.fromList(List.filled(32, 1)),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, 2)),
          listenAddress: '127.0.0.1:0',
          receiveDirectory: '/tmp/receive',
        ),
      ),
      codec.upsertPeerCommand(
        commandId: 'upsert',
        peer: PeerConfig(
          peerId: 'peer-a',
          endpointAddress: '127.0.0.1:4433',
          identityPublicKey: Uint8List.fromList(List.filled(32, 3)),
          e2ePublicKey: Uint8List.fromList(List.filled(32, 4)),
        ),
      ),
      codec.removePeerCommand(commandId: 'remove', peerId: 'peer-a'),
      codec.disconnectPeerCommand(commandId: 'disconnect', peerId: 'peer-a'),
      codec.sendFileCommand(
        commandId: 'send',
        transferId: 'transfer-a',
        peerId: 'peer-a',
        filePath: '/tmp/payload.bin',
      ),
      codec.cancelTransferCommand(
        commandId: 'cancel',
        transferId: 'transfer-a',
      ),
      codec.respondIncomingTransferCommand(
        commandId: 'accept',
        transferId: 'transfer-a',
        accept: true,
      ),
      codec.respondIncomingTransferCommand(
        commandId: 'reject',
        transferId: 'transfer-a',
        accept: false,
      ),
      codec.configureRelayCommand(
        commandId: 'relay',
        config: RelayConfig(
          relayUrl: 'wss://relay.example.test/ws',
          relayCredential: 'credential',
          relaySigningSeed: Uint8List.fromList(List.filled(32, 5)),
        ),
      ),
    ];

    expect(commands, everyElement(isNotEmpty));
    expect(
      commands.map(codec.commandId),
      containsAll(<String>[
        'configure',
        'upsert',
        'disconnect',
        'send',
        'cancel',
        'accept',
        'reject',
        'relay',
      ]),
    );
  });

  test('peer registration carries explicit Direct and Relay authorization', () {
    final encoded = codec.upsertPeerCommand(
      commandId: 'u',
      peer: PeerConfig(
        peerId: 'peer-a',
        endpointAddress: '',
        identityPublicKey: Uint8List(32),
        e2ePublicKey: Uint8List(32),
        allowDirect: true,
        allowRelay: true,
      ),
    );

    // PeerConfig fields 6 and 7 are bool route authorizations.  They are
    // intentionally carried on the V2 command rather than inferred from
    // endpoint discovery or local Relay enrollment.
    expect(_containsSubsequence(encoded, <int>[0x28, 0x00]), isTrue);
    expect(_containsSubsequence(encoded, <int>[0x30, 0x01]), isTrue);
    expect(_containsSubsequence(encoded, <int>[0x38, 0x01]), isTrue);
  });

  test(
    'remaining V2 event families preserve optional fields and unknown data',
    () {
      final error = <int>[
        ..._varintField(1, NetworkErrorCode.peerOffline.wireValue),
        ..._bytesField(2, utf8.encode('peer is offline')),
        ..._bytesField(3, utf8.encode(NetworkOperation.connect.wireName)),
        ..._bytesField(4, utf8.encode('peer-a')),
        ..._varintField(5, RetryDisposition.retryAfter.wireValue),
        ..._varintField(6, 9),
        ..._unknownFields(),
      ];

      final peerState = codec.decodeEvent(
        Uint8List.fromList(
          _frame(10, <int>[
            ..._bytesField(1, utf8.encode('peer-a')),
            ..._varintField(2, PeerConnectionState.failed.wireValue),
            ..._varintField(3, NetworkRouteType.relay.wireValue),
            ..._bytesField(4, error),
            ..._varintField(5, NetworkRouteTopology.relay.wireValue),
            ..._varintField(6, NetworkRouteTransport.webSocket.wireValue),
            ..._unknownFields(),
          ]),
        ),
      );
      expect(peerState.event, isA<PeerStateChanged>());
      final peerEvent = peerState.event! as PeerStateChanged;
      expect(peerEvent.error?.retryAfterSeconds, 9);
      expect(peerEvent.routeType, NetworkRouteType.relay);

      final progress =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      _frame(11, <int>[
                        ..._bytesField(1, utf8.encode('transfer-a')),
                        ..._varintField(2, 10),
                        ..._varintField(3, 100),
                        ..._unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as TransferProgress;
      expect(progress.bytesTransferred, 10);
      expect(progress.totalBytes, 100);

      final offer =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      _frame(14, <int>[
                        ..._bytesField(1, utf8.encode('transfer-a')),
                        ..._bytesField(2, utf8.encode('peer-a')),
                        ..._bytesField(3, utf8.encode('payload.bin')),
                        ..._varintField(4, 4096),
                        ..._varintField(5, NetworkRouteType.relay.wireValue),
                        ..._unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as IncomingTransferOffer;
      expect(offer.fileName, 'payload.bin');
      expect(offer.fileSize, 4096);
      expect(offer.routeType, NetworkRouteType.relay);

      final completed =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      _frame(15, <int>[
                        ..._bytesField(1, utf8.encode('transfer-a')),
                        ..._bytesField(2, utf8.encode('/receive/payload.bin')),
                        ..._unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as TransferCompleted;
      expect(completed.localPath, '/receive/payload.bin');

      final failed =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      _frame(16, <int>[
                        ..._bytesField(1, utf8.encode('transfer-a')),
                        ..._bytesField(2, error),
                        ..._unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as TransferFailed;
      expect(failed.error.code, NetworkErrorCode.peerOffline);
      expect(failed.error.operation, NetworkOperation.connect);

      final route =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      _frame(17, <int>[
                        ..._bytesField(1, utf8.encode('peer-a')),
                        ..._varintField(
                          2,
                          NetworkRouteType.quicDirect.wireValue,
                        ),
                        ..._bytesField(3, utf8.encode('203.0.113.8:4433')),
                        ..._varintField(4, 26),
                        ..._varintField(5, 7),
                        ..._varintField(
                          6,
                          NetworkRouteTopology.direct.wireValue,
                        ),
                        ..._varintField(
                          7,
                          NetworkRouteTransport.quic.wireValue,
                        ),
                        ..._unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as RouteChanged;
      expect(route.snapshot.endpoint, '203.0.113.8:4433');
      expect(route.snapshot.rtt, const Duration(milliseconds: 26));
      expect(route.snapshot.loss, 0.007);
      expect(route.snapshot.transport, NetworkRouteTransport.quic);

      final attempt =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      _frame(33, <int>[
                        ..._bytesField(1, utf8.encode('peer-a')),
                        ..._bytesField(2, utf8.encode('attempt-a')),
                        ..._varintField(
                          3,
                          RouteAttemptPhase.relayFallbackStarted.wireValue,
                        ),
                        ..._varintField(4, NetworkRouteType.relay.wireValue),
                        ..._bytesField(5, error),
                        ..._unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as RouteAttemptChanged;
      expect(attempt.peerId, 'peer-a');
      expect(attempt.attemptId, 'attempt-a');
      expect(attempt.phase, RouteAttemptPhase.relayFallbackStarted);
      expect(attempt.routeType, NetworkRouteType.relay);
      expect(attempt.error?.code, NetworkErrorCode.peerOffline);

      final relay =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      _frame(18, <int>[
                        ..._varintField(
                          1,
                          RelayConnectionState.failed.wireValue,
                        ),
                        ..._bytesField(2, error),
                        ..._unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as RelayStateChanged;
      expect(relay.state, RelayConnectionState.failed);
      expect(relay.error?.peerId, 'peer-a');

      final legacyResult = codec.decodeEvent(
        Uint8List.fromList(
          _frame(13, <int>[
            ..._bytesField(1, utf8.encode('command-a')),
            ..._varintField(2, 0),
            ..._bytesField(3, error),
            ..._unknownFields(),
          ]),
        ),
      );
      expect(legacyResult.commandId, 'command-a');
      expect(legacyResult.commandAccepted, isFalse);
      expect(legacyResult.commandError?.code, NetworkErrorCode.peerOffline);
    },
  );

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

    final missingHandle = _frame(26, <int>[
      ..._bytesField(1, utf8.encode('peer-a')),
    ]);
    expect(
      () => codec.decodeEvent(Uint8List.fromList(missingHandle)),
      throwsA(isA<FormatException>()),
    );

    final invalidHandle = _frame(27, <int>[
      ..._bytesField(1, utf8.encode('peer-a')),
      ..._bytesField(2, <int>[
        ..._bytesField(1, <int>[]),
        ..._varintField(2, 0),
      ]),
    ]);
    expect(
      () => codec.decodeEvent(Uint8List.fromList(invalidHandle)),
      throwsA(isA<FormatException>()),
    );
  });

  group('Network V2 transfer event peer ownership codec contract', () {
    test(
      'tag 32 (PeerTransferProgressEvent) decodes peerId and progress to TransferProgress',
      () {
        final frame = codec.decodeEvent(
          Uint8List.fromList(
            _frame(32, <int>[
              ..._bytesField(1, utf8.encode('peer-a')),
              ..._bytesField(2, utf8.encode('tx-1')),
              ..._varintField(3, 4096),
              ..._varintField(4, 8192),
              ..._varintField(5, 0), // paused = false
              ..._unknownFields(),
            ]),
          ),
        );

        expect(frame.event, isA<TransferProgress>());
        final progress = frame.event! as TransferProgress;
        expect(progress.peerId, 'peer-a');
        expect(progress.transferId, 'tx-1');
        expect(progress.bytesTransferred, 4096);
        expect(progress.totalBytes, 8192);
      },
    );

    test(
      'tag 11 (TransferProgressEvent) preserves peerId in TransferProgress',
      () {
        final frame = codec.decodeEvent(
          Uint8List.fromList(
            _frame(11, <int>[
              ..._bytesField(1, utf8.encode('tx-2')),
              ..._varintField(2, 1024),
              ..._varintField(3, 2048),
              ..._bytesField(4, utf8.encode('peer-b')),
              ..._unknownFields(),
            ]),
          ),
        );

        expect(frame.event, isA<TransferProgress>());
        final progress = frame.event! as TransferProgress;
        expect(progress.peerId, 'peer-b');
        expect(progress.transferId, 'tx-2');
        expect(progress.bytesTransferred, 1024);
        expect(progress.totalBytes, 2048);
      },
    );

    test(
      'tag 15 (TransferCompletedEvent) preserves peerId in TransferCompleted',
      () {
        final frame = codec.decodeEvent(
          Uint8List.fromList(
            _frame(15, <int>[
              ..._bytesField(1, utf8.encode('tx-3')),
              ..._bytesField(2, utf8.encode('/tmp/received_file.bin')),
              ..._bytesField(3, utf8.encode('peer-c')),
              ..._unknownFields(),
            ]),
          ),
        );

        expect(frame.event, isA<TransferCompleted>());
        final completed = frame.event! as TransferCompleted;
        expect(completed.peerId, 'peer-c');
        expect(completed.transferId, 'tx-3');
        expect(completed.localPath, '/tmp/received_file.bin');
      },
    );

    test('tag 16 (TransferFailedEvent) preserves peerId in TransferFailed', () {
      final error = <int>[
        ..._varintField(1, NetworkErrorCode.ioError.wireValue),
        ..._bytesField(2, utf8.encode('io error')),
        ..._bytesField(3, utf8.encode(NetworkOperation.send.wireName)),
        ..._bytesField(4, utf8.encode('peer-d')),
      ];

      final frame = codec.decodeEvent(
        Uint8List.fromList(
          _frame(16, <int>[
            ..._bytesField(1, utf8.encode('tx-4')),
            ..._bytesField(2, error),
            ..._bytesField(3, utf8.encode('peer-d')),
            ..._unknownFields(),
          ]),
        ),
      );

      expect(frame.event, isA<TransferFailed>());
      final failed = frame.event! as TransferFailed;
      expect(failed.peerId, 'peer-d');
      expect(failed.transferId, 'tx-4');
      expect(failed.error.code, NetworkErrorCode.ioError);
    });
  });
}

bool _containsSubsequence(List<int> bytes, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= bytes.length - needle.length; start++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (bytes[start + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

List<int> _frame(int eventField, List<int> payload) => <int>[
  ..._bytesField(1, utf8.encode('event-a')),
  ..._varintField(2, 123),
  ..._varintField(3, 2),
  ..._bytesField(eventField, payload),
];

List<int> _varintField(int fieldNumber, int value) => <int>[
  ..._varint(fieldNumber << 3),
  ..._varint(value),
];

List<int> _bytesField(int fieldNumber, List<int> value) => <int>[
  ..._varint((fieldNumber << 3) | 2),
  ..._varint(value.length),
  ...value,
];

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    final next = remaining & 0x7f;
    remaining >>= 7;
    bytes.add(remaining == 0 ? next : next | 0x80);
  } while (remaining != 0);
  return bytes;
}

List<int> _unknownFields() => <int>[
  ..._varintField(50, 1),
  ..._varint((51 << 3) | 1),
  ...List<int>.filled(8, 0xab),
  ..._bytesField(52, <int>[0xcd, 0xef]),
  ..._varint((53 << 3) | 5),
  ...List<int>.filled(4, 0x12),
];
