// 原生网络 package 的 v1 ABI 与 helper isolate 生命周期测试。

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// 执行 v1 原生 ABI 与 helper isolate 生命周期测试。
void main() {
  const native = SshMobileNetworkNative();

  test('SshMobileNetworkNative ABI version check', () {
    expect(native.getAbiVersion(), equals(1));
  });

  test('NetworkRuntime FFI lifecycle works', () {
    final handlePtr = calloc<Pointer<Void>>();
    try {
      final createRes = sshNetRuntimeCreateNative(handlePtr);
      expect(createRes, equals(0));
      expect(handlePtr.value, isNot(equals(nullptr)));

      final startRes = sshNetRuntimeStartNative(handlePtr.value);
      expect(startRes, equals(0));

      final isolate = native.createIsolate(handlePtr.value);
      expect(isolate, isNotNull);

      final stopRes = sshNetRuntimeStopNative(handlePtr.value);
      expect(stopRes, equals(0));
      final destroyRes = sshNetRuntimeDestroyNative(handlePtr.value);
      expect(destroyRes, equals(0));
    } finally {
      calloc.free(handlePtr);
    }
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
    expect(runtime.sendCommand(command), 0);
    expect(await eventFuture, isNotEmpty);
  });

  test('native runtime stops before it is destroyed', () async {
    final runtime = await native.createRuntime();
    final status = await runtime.stop();
    expect(status, equals(0));
    expect(runtime.sendCommand(Uint8List.fromList(<int>[0x00])), equals(-4));
    await runtime.dispose();
  });
}
