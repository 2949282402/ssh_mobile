import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

  Future<NativeNetworkRuntime> createRuntime() async {
    final outHandle = calloc<Pointer<Void>>();
    try {
      final createResult = sshNetRuntimeCreateNative(outHandle);
      if (createResult != 0 || outHandle.value == nullptr) {
        throw StateError(
          'Native network runtime creation failed ($createResult).',
        );
      }
      final handle = outHandle.value;
      final startResult = sshNetRuntimeStartNative(handle);
      if (startResult != 0) {
        sshNetRuntimeDestroyNative(handle);
        throw StateError('Native network runtime start failed ($startResult).');
      }
      final poller = NetworkNativeIsolate(handle);
      try {
        await poller.startPolling();
      } catch (_) {
        sshNetRuntimeDestroyNative(handle);
        rethrow;
      }
      return NativeNetworkRuntime._(handle, poller);
    } finally {
      calloc.free(outHandle);
    }
  }
}

class NativeNetworkRuntime {
  NativeNetworkRuntime._(this._handle, this._poller);

  Pointer<Void> _handle;
  final NetworkNativeIsolate _poller;

  Stream<Uint8List> get rawEvents => _poller.rawEvents;

  int sendCommand(Uint8List command) {
    if (_handle == nullptr) return -1;
    return _poller.sendCommand(command);
  }

  Future<void> dispose() async {
    final handle = _handle;
    if (handle == nullptr) return;
    _handle = nullptr;
    await _poller.stop();
    final result = sshNetRuntimeDestroyNative(handle);
    if (result != 0) {
      throw StateError('Native network runtime destroy failed ($result).');
    }
  }
}
