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
}
