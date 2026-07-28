import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

void main() {
  const native = SshMobileNetworkNative();

  test('SshMobileNetworkNative ABI and SDK version check', () {
    expect(native.getAbiVersion(), equals(1));
    expect(native.getSdkVersion(), equals(100));
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

      final destroyRes = sshNetRuntimeDestroyNative(handlePtr.value);
      expect(destroyRes, equals(0));
    } finally {
      calloc.free(handlePtr);
    }
  });
}
