// 原生网络 package 的 v1 ABI 与 helper isolate 生命周期测试。

import 'dart:typed_data';
import 'package:test/test.dart';
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
}
