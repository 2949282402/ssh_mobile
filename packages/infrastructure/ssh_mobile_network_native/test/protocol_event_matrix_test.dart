import 'dart:typed_data';

import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:test/test.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';
  final payload = Uint8List.fromList(<int>[0x76, 0x3d, 0x30]);
  final handle = NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7);

  test('native operation status maps every C ABI terminal code', () {
    expect(
      NativeOperationStatus.fromNativeCode(0),
      NativeOperationStatus.success,
    );
    expect(
      NativeOperationStatus.fromNativeCode(-1),
      NativeOperationStatus.invalidArgument,
    );
    expect(
      NativeOperationStatus.fromNativeCode(-2),
      NativeOperationStatus.invalidArgument,
    );
    expect(
      NativeOperationStatus.fromNativeCode(-4),
      NativeOperationStatus.stopped,
    );
    expect(
      NativeOperationStatus.fromNativeCode(99),
      NativeOperationStatus.failure,
    );
  });

  test('all public V2 command builders accept bounded edge values', () {
    final config = NativePeerConfig(
      peerId: 'peer-a',
      endpointAddress: 'quic://peer.example:443',
      identityPublicKey: Uint8List(32),
      e2ePublicKey: Uint8List(32),
      e2eePolicy: NativeE2eePolicy.disabled,
    );

    final commands = <Uint8List>[
      NativeNetworkProtocol.connectPeerCommand(
        commandId: 'connect',
        peerId: 'peer-a',
        intent: 1,
        communicationClass: 5,
      ),
      NativeNetworkProtocol.disconnectPeerCommand(
        commandId: 'disconnect',
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.sendMessageCommand(
        commandId: 'message',
        peerId: 'peer-a',
        channelId: 'channel-a',
        payload: payload,
        deliveryPolicy: 3,
      ),
      NativeNetworkProtocol.sendMessageV2Command(
        commandId: 'message-v2',
        peerId: 'peer-a',
        messageId: 'message-a',
        channelId: 'channel-a',
        payload: payload,
        deliveryPolicy: 3,
        e2eePolicy: NativeE2eePolicy.disabled,
      ),
      NativeNetworkProtocol.upsertPeerV2Command(
        commandId: 'upsert',
        config: config,
      ),
      NativeNetworkProtocol.removePeerCommand(
        commandId: 'remove',
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.transferCommand(
        commandId: 'transfer',
        peerId: 'peer-a',
        transferId: 'transfer-a',
        filePath: '/tmp/file.bin',
        confirmedOffset: 42,
        resume: true,
      ),
      NativeNetworkProtocol.peerDiagnosticsCommand(
        commandId: 'diagnostics',
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.networkEnvironmentChangedCommand(
        commandId: 'environment',
        generation: 9,
        hasConnectivity: true,
        isForeground: false,
        isMetered: true,
      ),
      NativeNetworkProtocol.sendFileCommand(
        commandId: 'file',
        peerId: 'peer-a',
        transferId: 'transfer-a',
        filePath: '/tmp/file.bin',
      ),
      NativeNetworkProtocol.cancelTransferCommand(
        commandId: 'cancel',
        transferId: 'transfer-a',
      ),
      NativeNetworkProtocol.startRealtimeSessionCommand(
        commandId: 'realtime-start',
        realtimeId: realtimeId,
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.stopRealtimeSessionCommand(
        commandId: 'realtime-stop',
        realtimeId: realtimeId,
      ),
      NativeNetworkProtocol.sendRealtimeSignalCommand(
        commandId: 'signal',
        realtimeId: realtimeId,
        peerId: 'peer-a',
        kind: NativeRealtimeSignalKind.webRtcOffer,
        revision: 1,
        payload: payload,
      ),
      NativeNetworkProtocol.sshStreamOpenCommand(
        commandId: 'stream-open',
        peerId: 'peer-a',
        handle: handle,
        service: 'ssh-session',
      ),
      NativeNetworkProtocol.sshStreamDataCommand(
        commandId: 'stream-data',
        peerId: 'peer-a',
        handle: handle,
        data: payload,
      ),
      NativeNetworkProtocol.sshStreamCloseCommand(
        commandId: 'stream-close',
        peerId: 'peer-a',
        handle: handle,
      ),
    ];

    expect(commands, hasLength(17));
    for (final command in commands) {
      expect(command, isNotEmpty);
      expect(command, isA<Uint8List>());
    }
  });

  test('peer registration carries explicit route authorization flags', () {
    final encoded = NativeNetworkProtocol.upsertPeerV2Command(
      commandId: 'upsert-routes',
      config: NativePeerConfig(
        peerId: 'peer-a',
        endpointAddress: '',
        identityPublicKey: Uint8List(32),
        e2ePublicKey: Uint8List(32),
        allowDirect: true,
        allowRelay: true,
      ),
    );

    expect(_containsSubsequence(encoded, <int>[0x30, 0x01]), isTrue);
    expect(_containsSubsequence(encoded, <int>[0x38, 0x01]), isTrue);
  });

  test('all V2 event families decode their bounded fields and errors', () {
    final error = _message(<List<int>>[
      _varintField(1, 7),
      _stringField(2, 'failed'),
      _stringField(3, 'connect'),
      _stringField(4, 'peer-a'),
      _varintField(5, NativeRetryDisposition.retryAfter.wireValue),
      _varintField(6, 5),
    ]);
    final streamHandle = _message(<List<int>>[
      _stringField(1, 'device-a'),
      _varintField(2, 7),
    ]);
    final presence = _message(<List<int>>[
      _stringField(1, 'peer-a'),
      _varintField(2, 4),
      _varintField(3, NativePeerPresenceState.updated.wireValue),
    ]);
    final eventPayloads = <int, List<int>>{
      10: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, NativePeerConnectionState.connected.wireValue),
        _varintField(3, NativeRouteType.quicDirect.wireValue),
        _bytesField(4, error),
        _varintField(5, NativeRouteTopology.direct.wireValue),
        _varintField(6, NativeRouteTransport.quic.wireValue),
      ]),
      11: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _varintField(2, 42),
        _varintField(3, 100),
      ]),
      13: _message(<List<int>>[
        _stringField(1, 'legacy-command'),
        _varintField(2, 1),
        _bytesField(3, error),
      ]),
      14: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _stringField(2, 'peer-a'),
        _stringField(3, 'file.bin'),
        _varintField(4, 1024),
        _varintField(5, NativeRouteType.relay.wireValue),
      ]),
      15: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _stringField(2, '/tmp/file.bin'),
      ]),
      16: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _bytesField(2, error),
      ]),
      18: _message(<List<int>>[
        _varintField(1, NativeRelayConnectionState.connected.wireValue),
        _bytesField(2, error),
      ]),
      19: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'session-a'),
        _stringField(3, 'channel-a'),
        _bytesField(4, <int>[1, 2, 3]),
        _varintField(5, 8),
        _bytesField(7, <int>[4, 5]),
      ]),
      20: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'session-a'),
        _bytesField(3, <int>[1, 2, 3]),
        _varintField(4, 9),
      ]),
      21: _message(<List<int>>[
        _stringField(1, realtimeId),
        _stringField(2, 'peer-a'),
        _varintField(3, NativeRealtimeSessionState.connected.wireValue),
        _varintField(4, 3),
        _bytesField(5, error),
      ]),
      22: _message(<List<int>>[
        _stringField(1, realtimeId),
        _stringField(2, 'peer-a'),
        _varintField(3, NativeRealtimeSignalKind.webRtcAnswer.wireValue),
        _varintField(4, 4),
        _bytesField(5, <int>[6, 7]),
      ]),
      23: _message(<List<int>>[
        _stringField(1, realtimeId),
        _stringField(2, 'peer-a'),
        _varintField(3, NativeRealtimeSessionState.negotiating.wireValue),
        _varintField(4, 5),
        _bytesField(5, error),
      ]),
      24: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, 10),
        _varintField(3, NativePeerPresenceState.online.wireValue),
      ]),
      25: _message(<List<int>>[_bytesField(1, presence)]),
      28: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, NativePeerState.online.wireValue),
        _varintField(3, NativeE2eePolicy.disabled.wireValue),
        _bytesField(4, error),
      ]),
      29: _message(<List<int>>[
        _stringField(1, 'command-v2'),
        _stringField(2, 'peer-a'),
        _varintField(3, 1),
        _bytesField(4, error),
      ]),
      30: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, NativePeerState.online.wireValue),
        _varintField(3, NativeE2eePolicy.disabled.wireValue),
        _varintField(4, 1),
        _varintField(5, 2),
        _varintField(6, 3),
        _varintField(7, 4),
        _bytesField(8, error),
      ]),
      31: _message(<List<int>>[
        _varintField(1, 12),
        _varintField(2, 1),
        _varintField(3, 1),
        _varintField(4, 0),
      ]),
      32: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'transfer-a'),
        _varintField(3, 10),
        _varintField(4, 100),
        _varintField(5, 1),
      ]),
      33: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'attempt-a'),
        _varintField(3, NativeRouteAttemptPhase.relayFallbackStarted.wireValue),
        _varintField(4, NativeRouteType.relay.wireValue),
        _bytesField(5, error),
        _stringField(6, 'command-a'),
      ]),
      26: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _bytesField(2, streamHandle),
        _bytesField(3, <int>[8, 9]),
      ]),
      27: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _bytesField(2, streamHandle),
      ]),
    };

    final decoded = <int, NativeNetworkEvent?>{
      for (final entry in eventPayloads.entries)
        entry.key: NativeNetworkProtocol.decodeEvent(
          _event(entry.key, entry.value),
        ),
    };

    expect(decoded[10], isA<NativePeerStateChangedEvent>());
    expect(decoded[11], isA<NativeTransferProgressEvent>());
    expect(decoded[13], isA<NativeCommandResultEvent>());
    expect(decoded[14], isA<NativeIncomingTransferOfferEvent>());
    expect(decoded[15], isA<NativeTransferCompletedEvent>());
    expect(decoded[16], isA<NativeTransferFailedEvent>());
    expect(decoded[18], isA<NativeRelayStateChangedEvent>());
    expect(decoded[19], isA<NativeChannelMessageEvent>());
    expect(decoded[20], isA<NativeDeliveryAckedEvent>());
    expect(decoded[21], isA<NativeRealtimeStateChangedEvent>());
    expect(decoded[22], isA<NativeRealtimeSignalEvent>());
    expect(decoded[23], isA<NativeRealtimeSnapshotEvent>());
    expect(decoded[24], isA<NativePeerPresenceChangedEvent>());
    expect(decoded[25], isA<NativePeerPresenceSnapshotEvent>());
    expect(decoded[26], isA<NativeSshStreamDataReceivedEvent>());
    expect(decoded[27], isA<NativeSshStreamClosedEvent>());
    expect(decoded[28], isA<NativePeerLifecycleEvent>());
    expect(decoded[29], isA<NativeCommandResultV2Event>());
    expect(decoded[30], isA<NativePeerDiagnosticsEvent>());
    expect(decoded[31], isA<NativeNetworkEnvironmentChangedEvent>());
    expect(decoded[32], isA<NativePeerTransferProgressEvent>());
    expect(decoded[33], isA<NativeRouteAttemptChangedEvent>());

    final routeAttempt = decoded[33]! as NativeRouteAttemptChangedEvent;
    expect(routeAttempt.peerId, 'peer-a');
    expect(routeAttempt.attemptId, 'attempt-a');
    expect(routeAttempt.phase, NativeRouteAttemptPhase.relayFallbackStarted);
    expect(routeAttempt.routeType, NativeRouteType.relay);
    expect(routeAttempt.error?.code, 7);
    expect(routeAttempt.commandId, 'command-a');

    final diagnostics = decoded[30]! as NativePeerDiagnosticsEvent;
    expect(diagnostics.activeTransferCount, 4);
    expect(diagnostics.lastError?.retryAfterSeconds, 5);
    final signal = decoded[22]! as NativeRealtimeSignalEvent;
    expect(signal.payload, orderedEquals(<int>[6, 7]));
    final presenceSnapshot = decoded[25]! as NativePeerPresenceSnapshotEvent;
    expect(presenceSnapshot.peers.single.generation, 4);
  });

  test(
    'protocol decoder fails closed for malformed envelopes and unknown tags',
    () {
      expect(
        () => NativeNetworkProtocol.decodeEvent(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => NativeNetworkProtocol.decodeEvent(
          _event(
            21,
            _message(<List<int>>[_stringField(1, 'not-a-realtime-id')]),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        NativeNetworkProtocol.decodeEvent(
          _event(99, _message(<List<int>>[_varintField(1, 1)])),
        ),
        isNull,
      );
      expect(
        () => NativeNetworkProtocol.startRealtimeSessionCommand(
          commandId: 'invalid',
          realtimeId: 'GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG',
          peerId: 'peer-a',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => NativeNetworkProtocol.sendRealtimeSignalCommand(
          commandId: 'invalid-signal',
          realtimeId: realtimeId,
          peerId: 'peer-a',
          kind: NativeRealtimeSignalKind.unspecified,
          revision: 1,
          payload: Uint8List(0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => NativeNetworkProtocol.sshStreamOpenCommand(
          commandId: 'bad-stream',
          peerId: 'peer-a',
          handle: NativeStreamHandle(openerDeviceId: 'device-a', streamId: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'native enum wire mappings round-trip and default unknown values safely',
    () {
      for (final value in NativePeerConnectionState.values) {
        expect(NativePeerConnectionState.fromWire(value.wireValue), value);
      }
      for (final value in NativePeerState.values) {
        expect(NativePeerState.fromWire(value.wireValue), value);
      }
      for (final value in NativeRouteType.values) {
        expect(NativeRouteType.fromWire(value.wireValue), value);
      }
      for (final value in NativeRouteTopology.values) {
        expect(NativeRouteTopology.fromWire(value.wireValue), value);
      }
      for (final value in NativeRouteTransport.values) {
        expect(NativeRouteTransport.fromWire(value.wireValue), value);
      }
      for (final value in NativeRelayConnectionState.values) {
        expect(NativeRelayConnectionState.fromWire(value.wireValue), value);
      }
      for (final value in NativeRealtimeSessionState.values) {
        expect(NativeRealtimeSessionState.fromWire(value.wireValue), value);
      }
      for (final value in NativeRealtimeSignalKind.values) {
        expect(NativeRealtimeSignalKind.fromWire(value.wireValue), value);
      }
      for (final value in NativeRetryDisposition.values) {
        expect(NativeRetryDisposition.fromWire(value.wireValue), value);
      }
      for (final value in NativePeerPresenceState.values) {
        expect(NativePeerPresenceState.fromWire(value.wireValue), value);
      }
      expect(
        NativePeerConnectionState.fromWire(-1),
        NativePeerConnectionState.unspecified,
      );
      expect(NativePeerState.fromWire(-1), NativePeerState.offline);
      expect(NativeRouteType.fromWire(-1), NativeRouteType.unspecified);
      expect(NativeRouteTopology.fromWire(-1), NativeRouteTopology.unspecified);
      expect(
        NativeRouteTransport.fromWire(-1),
        NativeRouteTransport.unspecified,
      );
      expect(
        NativeRelayConnectionState.fromWire(-1),
        NativeRelayConnectionState.unspecified,
      );
      expect(
        NativeRealtimeSessionState.fromWire(-1),
        NativeRealtimeSessionState.unspecified,
      );
      expect(
        NativeRealtimeSignalKind.fromWire(-1),
        NativeRealtimeSignalKind.unspecified,
      );
      expect(
        NativeRetryDisposition.fromWire(-1),
        NativeRetryDisposition.unspecified,
      );
      expect(
        NativePeerPresenceState.fromWire(-1),
        NativePeerPresenceState.unspecified,
      );
    },
  );

  test(
    'command guards and bounded builders reject invalid ownership inputs',
    () {
      expect(
        () => NativeCommandResultGuard(maxPendingCommands: 0),
        throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
      );
      final guard = NativeCommandResultGuard();
      expect(() => guard.register(''), throwsArgumentError);
      expect(() => guard.register('x' * 129), throwsArgumentError);

      expect(
        () => NativeNetworkProtocol.sendMessageCommand(
          commandId: 'message',
          peerId: 'peer-a',
          channelId: '',
          payload: Uint8List(0),
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeNetworkProtocol.sendMessageCommand(
          commandId: 'message',
          peerId: 'peer-a',
          channelId: 'channel-a',
          payload: Uint8List(384 * 1024 + 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeNetworkProtocol.sendMessageV2Command(
          commandId: 'message-v2',
          peerId: 'peer-a',
          messageId: 'message-a',
          channelId: 'channel-a',
          payload: Uint8List(384 * 1024 + 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeNetworkProtocol.transferCommand(
          commandId: 'transfer',
          peerId: 'peer-a',
          transferId: 'transfer-a',
          filePath: '/tmp/file.bin',
          confirmedOffset: -1,
        ),
        throwsArgumentError,
      );

      const handle = NativeStreamHandle(
        openerDeviceId: 'device-a',
        streamId: 7,
      );
      expect(
        handle ==
            const NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7),
        isTrue,
      );
      expect(
        handle.hashCode,
        const NativeStreamHandle(
          openerDeviceId: 'device-a',
          streamId: 7,
        ).hashCode,
      );
      final dataEvent = NativeSshStreamDataReceivedEvent(
        eventId: 'event',
        timestampMs: 1,
        protocolVersion: NativeNetworkProtocol.protocolVersion,
        peerId: 'peer-a',
        handle: handle,
        data: Uint8List.fromList(<int>[1]),
      );
      expect(dataEvent.openerDeviceId, 'device-a');
      expect(dataEvent.streamId, 7);
      const closedEvent = NativeSshStreamClosedEvent(
        eventId: 'event',
        timestampMs: 1,
        protocolVersion: NativeNetworkProtocol.protocolVersion,
        peerId: 'peer-a',
        handle: handle,
      );
      expect(closedEvent.openerDeviceId, 'device-a');
      expect(closedEvent.streamId, 7);
    },
  );
}

Uint8List _event(int payloadField, List<int> payload) =>
    Uint8List.fromList(<int>[
      ..._stringField(1, 'event-a'),
      ..._varintField(2, 42),
      ..._varintField(3, NativeNetworkProtocol.protocolVersion),
      ..._bytesField(payloadField, payload),
    ]);

List<int> _message(Iterable<List<int>> fields) => <int>[
  ...fields.expand((field) => field),
];

List<int> _stringField(int number, String value) =>
    _bytesField(number, value.codeUnits);

List<int> _bytesField(int number, List<int> value) => <int>[
  ..._varint(_wireTag(number, 2)),
  ..._varint(value.length),
  ...value,
];

List<int> _varintField(int number, int value) => <int>[
  ..._varint(_wireTag(number, 0)),
  ..._varint(value),
];

int _wireTag(int number, int wireType) => (number << 3) | wireType;

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

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) byte |= 0x80;
    bytes.add(byte);
  } while (remaining != 0);
  return bytes;
}
