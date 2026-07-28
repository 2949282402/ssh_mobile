import 'dart:ffi';
import 'src/network_native_isolate.dart';
export 'src/ssh_net_buffer.dart';
export 'src/network_native_isolate.dart';

/// C ABI FFI bindings for ssh_mobile_network_native.

@Native<Uint32 Function()>(symbol: 'ssh_net_abi_version')
external int sshNetAbiVersionNative();

@Native<Uint32 Function()>(symbol: 'ssh_net_sdk_version')
external int sshNetSdkVersionNative();

@Native<Int32 Function(Pointer<Pointer<Void>>)>(
  symbol: 'ssh_net_runtime_create',
)
external int sshNetRuntimeCreateNative(Pointer<Pointer<Void>> outHandle);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_start')
external int sshNetRuntimeStartNative(Pointer<Void> handle);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_destroy')
external int sshNetRuntimeDestroyNative(Pointer<Void> handle);

/// Main entry point for native network SDK operations in Dart.
class SshMobileNetworkNative {
  const SshMobileNetworkNative();

  int getAbiVersion() => sshNetAbiVersionNative();

  int getSdkVersion() => sshNetSdkVersionNative();

  NetworkNativeIsolate? createIsolate(Pointer<Void> handle) {
    if (handle == nullptr) return null;
    return NetworkNativeIsolate(handle);
  }
}
