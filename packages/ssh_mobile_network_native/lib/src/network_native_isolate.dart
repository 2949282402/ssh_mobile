import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
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

/// Owns a real Dart isolate that performs blocking native event polling away
/// from Flutter's UI isolate.
class NetworkNativeIsolate {
  NetworkNativeIsolate(this.handle);

  final Pointer<Void> handle;
  final StreamController<Uint8List> _eventController =
      StreamController<Uint8List>.broadcast();
  ReceivePort? _receivePort;
  ReceivePort? _exitPort;
  Isolate? _worker;
  bool _isPolling = false;

  Stream<Uint8List> get rawEvents => _eventController.stream;

  Future<void> startPolling({
    Duration interval = const Duration(milliseconds: 50),
  }) async {
    if (_isPolling || handle == nullptr) return;
    _isPolling = true;
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    _receivePort = receivePort;
    _exitPort = exitPort;
    receivePort.listen((message) {
      if (message is Uint8List && !_eventController.isClosed) {
        _eventController.add(message);
      }
    });
    try {
      _worker = await Isolate.spawn<List<Object>>(
        _pollEvents,
        <Object>[
          handle.address,
          receivePort.sendPort,
          interval.inMilliseconds.clamp(1, 1000),
        ],
        onExit: exitPort.sendPort,
        debugName: 'ssh-network-native-events',
      );
    } catch (_) {
      _isPolling = false;
      receivePort.close();
      exitPort.close();
      _receivePort = null;
      _exitPort = null;
      rethrow;
    }
  }

  int sendCommand(Uint8List commandBytes) {
    if (handle == nullptr || commandBytes.isEmpty) return -1;

    final ptr = calloc<Uint8>(commandBytes.length);
    try {
      ptr.asTypedList(commandBytes.length).setAll(0, commandBytes);
      return sshNetRuntimeCommandNative(handle, ptr, commandBytes.length);
    } finally {
      calloc.free(ptr);
    }
  }

  Future<void> stop() async {
    _isPolling = false;
    final worker = _worker;
    final exitPort = _exitPort;
    if (worker != null && exitPort != null) {
      worker.kill(priority: Isolate.immediate);
      await exitPort.first.timeout(const Duration(seconds: 2));
    }
    _worker = null;
    exitPort?.close();
    _exitPort = null;
    _receivePort?.close();
    _receivePort = null;
    if (!_eventController.isClosed) {
      await _eventController.close();
    }
  }
}

void _pollEvents(List<Object> arguments) {
  final handle = Pointer<Void>.fromAddress(arguments[0] as int);
  final events = arguments[1] as SendPort;
  final timeoutMs = arguments[2] as int;

  while (true) {
    final outBuffer = calloc<SshNetBuffer>();
    try {
      final result = sshNetRuntimePollEventNative(handle, timeoutMs, outBuffer);
      if (result == 1) {
        final buffer = outBuffer.ref;
        if (buffer.ptr != nullptr && buffer.len > 0) {
          events.send(Uint8List.fromList(buffer.ptr.asTypedList(buffer.len)));
          sshNetBufferFreeNative(buffer);
        }
      } else if (result < 0) {
        return;
      }
    } finally {
      calloc.free(outBuffer);
    }
  }
}
