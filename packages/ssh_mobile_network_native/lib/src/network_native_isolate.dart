import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'ssh_net_buffer.dart';

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Size)>(
  symbol: 'ssh_net_runtime_command',
)
external int sshNetRuntimeCommandNative(
  Pointer<Void> handle,
  Pointer<Uint8> commandPtr,
  int commandLen,
);

@Native<Int32 Function(Pointer<Void>, Uint32, Pointer<SshNetBuffer>)>(
  symbol: 'ssh_net_runtime_poll_event',
)
external int sshNetRuntimePollEventNative(
  Pointer<Void> handle,
  int timeoutMs,
  Pointer<SshNetBuffer> outEvent,
);

@Native<Void Function(SshNetBuffer)>(symbol: 'ssh_net_buffer_free')
external void sshNetBufferFreeNative(SshNetBuffer buffer);

/// Manages event polling loop from the Rust NetworkRuntime.
class NetworkNativeIsolate {
  final Pointer<Void> handle;
  final StreamController<Uint8List> _eventController =
      StreamController<Uint8List>.broadcast();
  Timer? _pollTimer;
  bool _isPolling = false;

  NetworkNativeIsolate(this.handle);

  /// Raw binary event stream from native runtime.
  Stream<Uint8List> get rawEvents => _eventController.stream;

  /// Starts the event polling loop.
  void startPolling({Duration interval = const Duration(milliseconds: 50)}) {
    if (_isPolling) return;
    _isPolling = true;
    _pollTimer = Timer.periodic(interval, (_) => _pollOnce());
  }

  void _pollOnce() {
    if (!_isPolling || handle == nullptr) return;

    final outBuf = calloc<SshNetBuffer>();
    try {
      final res = sshNetRuntimePollEventNative(handle, 0, outBuf);
      if (res == 1) {
        final buffer = outBuf.ref;
        if (buffer.ptr != nullptr && buffer.len > 0) {
          final bytes = buffer.ptr.asTypedList(buffer.len);
          _eventController.add(Uint8List.fromList(bytes));
          sshNetBufferFreeNative(buffer);
        }
      }
    } finally {
      calloc.free(outBuf);
    }
  }

  /// Sends a raw Protobuf command buffer to native runtime.
  int sendCommand(Uint8List commandBytes) {
    if (handle == nullptr || commandBytes.isEmpty) return -1;

    final ptr = calloc<Uint8>(commandBytes.length);
    try {
      final nativeList = ptr.asTypedList(commandBytes.length);
      nativeList.setAll(0, commandBytes);
      return sshNetRuntimeCommandNative(handle, ptr, commandBytes.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Stops polling and closes stream.
  void stop() {
    _isPolling = false;
    _pollTimer?.cancel();
    _eventController.close();
  }
}
