// 原生网络 package 的 v1 ABI 与 helper isolate 生命周期测试。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// 执行 v1 原生 ABI 与 helper isolate 生命周期测试。
void main() {
  const native = SshMobileNetworkNative();

  test('SshMobileNetworkNative ABI version check', () {
    expect(native.getAbiVersion(), equals(1));
  });

  test('NativeNetworkRuntime lifecycle uses typed status', () async {
    final runtime = await native.createRuntime();
    expect(
      runtime.sendCommand(Uint8List(0)),
      NativeOperationStatus.invalidArgument,
    );
    expect(await runtime.stop(), NativeOperationStatus.success);
    expect(
      runtime.sendCommand(Uint8List.fromList(<int>[0x00])),
      NativeOperationStatus.stopped,
    );
    await runtime.dispose();
  });

  test('native runtime polls events on a helper isolate', () async {
    final runtime = await native.createRuntime();
    addTearDown(runtime.dispose);

    final eventFuture = runtime.rawEvents.first.timeout(
      const Duration(seconds: 2),
    );
    final command = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'cmd'.codeUnits,
      0x10,
      0x01,
    ]);
    expect(runtime.sendCommand(command), NativeOperationStatus.success);
    expect(await eventFuture, isNotEmpty);
  });

  test('native runtime stops before it is destroyed', () async {
    final runtime = await native.createRuntime();
    final status = await runtime.stop();
    expect(status, NativeOperationStatus.success);
    expect(
      runtime.sendCommand(Uint8List.fromList(<int>[0x00])),
      NativeOperationStatus.stopped,
    );
    await runtime.dispose();
  });

  test(
    'Realtime commands and typed events stay behind the native facade',
    () async {
      const realtimeId = '00112233445566778899aabbccddeeff';
      final runtime = await native.createRuntime();
      addTearDown(runtime.dispose);

      final resultFuture = runtime.events
          .where((event) => event is NativeCommandResultEvent)
          .cast<NativeCommandResultEvent>()
          .first
          .timeout(const Duration(seconds: 2));
      expect(
        runtime.startRealtimeSession(realtimeId: realtimeId, peerId: 'peer-a'),
        NativeOperationStatus.success,
      );
      final result = await resultFuture;
      expect(result.accepted, isFalse);
      expect(result.error?.code, isNotNull);
      expect(
        runtime.sendRealtimeSignal(
          realtimeId: 'INVALID',
          peerId: 'peer-a',
          kind: NativeRealtimeSignalKind.webRtcOffer,
          revision: 1,
          payload: Uint8List.fromList(<int>[118, 61, 48]),
        ),
        NativeOperationStatus.invalidArgument,
      );
    },
  );

  test('Realtime event decoder preserves bounded signaling payloads', () {
    final nested = <int>[
      0x0a,
      0x20,
      ...'00112233445566778899aabbccddeeff'.codeUnits,
      0x12,
      0x06,
      ...'peer-a'.codeUnits,
      0x18,
      NativeRealtimeSignalKind.webRtcOffer.wireValue,
      0x20,
      0x01,
      0x2a,
      0x05,
      0x76,
      0x3d,
      0x30,
      0x0d,
      0x0a,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x01,
      0xb2,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeRealtimeSignalEvent>());
    final signal = event! as NativeRealtimeSignalEvent;
    expect(signal.realtimeId, equals('00112233445566778899aabbccddeeff'));
    expect(signal.kind, NativeRealtimeSignalKind.webRtcOffer);
    expect(signal.payload, orderedEquals(<int>[118, 61, 48, 13, 10]));
  });

  test('Realtime protocol keeps v1 and ICE end-of-candidates semantics', () {
    expect(
      NativeNetworkProtocol.sendRealtimeSignalCommand(
        commandId: 'ice-end',
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        kind: NativeRealtimeSignalKind.iceCandidate,
        revision: 2,
        payload: Uint8List(0),
      ),
      isNotEmpty,
    );

    expect(
      () => NativeNetworkProtocol.decodeEvent(
        Uint8List.fromList(<int>[
          0x0a,
          0x03,
          ...'evt'.codeUnits,
          0x10,
          0x01,
          0x18,
          0x02,
        ]),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('Realtime snapshot event round-trips state and revision (tag 23)', () {
    final nested = <int>[
      0x0a,
      0x20,
      ...'00112233445566778899aabbccddeeff'.codeUnits,
      0x12,
      0x06,
      ...'peer-a'.codeUnits,
      0x18,
      NativeRealtimeSessionState.connected.wireValue,
      0x20,
      0x07,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x01,
      0xba,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeRealtimeSnapshotEvent>());
    final snapshot = event! as NativeRealtimeSnapshotEvent;
    expect(snapshot.realtimeId, equals('00112233445566778899aabbccddeeff'));
    expect(snapshot.peerId, equals('peer-a'));
    expect(snapshot.state, NativeRealtimeSessionState.connected);
    expect(snapshot.revision, 7);
    expect(snapshot.error, isNull);
  });

  test('Realtime snapshot decodes nested NetworkError with retry fields', () {
    final errorNested = <int>[
      0x08,
      12,
      0x12,
      0x03,
      ...'exp'.codeUnits,
      0x28,
      4,
      0x30,
      30,
    ];
    final nested = <int>[
      0x0a,
      0x20,
      ...'00112233445566778899aabbccddeeff'.codeUnits,
      0x12,
      0x06,
      ...'peer-a'.codeUnits,
      0x18,
      NativeRealtimeSessionState.failed.wireValue,
      0x20,
      0x03,
      0x2a,
      errorNested.length,
      ...errorNested,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x01,
      0xba,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    final snapshot = event! as NativeRealtimeSnapshotEvent;
    expect(snapshot.state, NativeRealtimeSessionState.failed);
    expect(snapshot.revision, 3);
    expect(snapshot.error, isNotNull);
    expect(snapshot.error!.code, 12);
    expect(
      snapshot.error!.retryDisposition,
      NativeRetryDisposition.refreshCredentialThenRetry,
    );
    expect(snapshot.error!.retryAfterSeconds, 30);
  });

  test('NetworkError decode preserves retry disposition and retry-after', () {
    final errorNested = <int>[
      0x08,
      12,
      0x12,
      0x03,
      ...'exp'.codeUnits,
      0x28,
      4,
      0x30,
      30,
    ];
    final nested = <int>[
      0x0a,
      0x03,
      ...'cmd'.codeUnits,
      0x10,
      0x00,
      0x1a,
      errorNested.length,
      ...errorNested,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x01,
      0x6a,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeCommandResultEvent>());
    final result = event! as NativeCommandResultEvent;
    expect(result.accepted, isFalse);
    expect(result.error, isNotNull);
    expect(result.error!.code, 12);
    expect(
      result.error!.retryDisposition,
      NativeRetryDisposition.refreshCredentialThenRetry,
    );
    expect(result.error!.retryAfterSeconds, 30);
  });

  test('SSH stream commands encode into tags 25/26/27', () {
    final open = NativeNetworkProtocol.sshStreamOpenCommand(
      commandId: 'open-1',
      peerId: 'peer-a',
      streamId: 7,
      service: 'ssh',
    );
    expect(open, isNotEmpty);
    expect(open, contains(0xca)); // field 25 key prefix
    expect(open, contains(0x07)); // stream_id = 7

    final data = NativeNetworkProtocol.sshStreamDataCommand(
      commandId: 'data-1',
      peerId: 'peer-a',
      streamId: 7,
      data: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
    );
    expect(data, isNotEmpty);
    expect(data, contains(0xd2)); // field 26 key prefix
    expect(data, contains(0xde));
    expect(data, contains(0xef));

    final close = NativeNetworkProtocol.sshStreamCloseCommand(
      commandId: 'close-1',
      peerId: 'peer-a',
      streamId: 7,
    );
    expect(close, isNotEmpty);
    expect(close, contains(0xda)); // field 27 key prefix
  });

  test('SSH stream data received event decodes from tag 26', () {
    final nested = <int>[
      0x0a, 0x06, ...'peer-a'.codeUnits, // peer_id = peer-a
      0x10, 0x07, // stream_id = 7
      0x1a, 0x04, 0x01, 0x02, 0x03, 0x04, // data
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x01,
      0xd2,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeSshStreamDataReceivedEvent>());
    final stream = event! as NativeSshStreamDataReceivedEvent;
    expect(stream.peerId, 'peer-a');
    expect(stream.streamId, 7);
    expect(stream.data, orderedEquals([1, 2, 3, 4]));
  });

  test('SSH stream closed event decodes from tag 27', () {
    final nested = <int>[0x0a, 0x06, ...'peer-a'.codeUnits, 0x10, 0x07];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x01,
      0xda,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeSshStreamClosedEvent>());
    final closed = event! as NativeSshStreamClosedEvent;
    expect(closed.peerId, 'peer-a');
    expect(closed.streamId, 7);
  });

  test('SSH stream commands reject invalid stream ids and services', () {
    expect(
      () => NativeNetworkProtocol.sshStreamOpenCommand(
        commandId: 'c',
        peerId: 'peer-a',
        streamId: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => NativeNetworkProtocol.sshStreamOpenCommand(
        commandId: 'c',
        peerId: 'peer-a',
        streamId: 7,
        service: '',
      ),
      throwsArgumentError,
    );
  });

  test('unknown future realtime event tag is ignored', () {
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x01,
      0xc2,
      0x01,
      0x02,
      0x08,
      0x01,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isNull);
  });
}
