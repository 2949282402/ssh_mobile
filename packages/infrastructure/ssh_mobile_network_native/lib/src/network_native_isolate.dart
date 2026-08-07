// v1 helper isolate 原生网络运行时轮询桥接。
//
// 原生运行时停止/销毁前必须先停止并确认 isolate，避免轮询访问已释放的运行时句柄。

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_operation_status.dart';
import 'ssh_net_buffer.dart';

/// 向原生运行时发送一个已编码命令。
@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Size)>(
  symbol: 'ssh_net_runtime_command',
)
external int _sshNetRuntimeCommandNative(
  Pointer<Void> handle,
  Pointer<Uint8> commandPtr,
  int commandLen,
);

/// 从原生运行时轮询一个事件帧。
@Native<Int32 Function(Pointer<Void>, Uint32, Pointer<SshNetBuffer>)>(
  symbol: 'ssh_net_runtime_poll_event',
)
external int _sshNetRuntimePollEventNative(
  Pointer<Void> handle,
  int timeoutMs,
  Pointer<SshNetBuffer> outEvent,
);

/// 释放轮询返回的原生事件缓冲区。
@Native<Void Function(SshNetBuffer)>(symbol: 'ssh_net_buffer_free')
external void _sshNetBufferFreeNative(SshNetBuffer buffer);

/// 拥有真实 Dart isolate，在 Flutter UI isolate 之外执行阻塞式原生事件轮询。
class NetworkNativeIsolate {
  /// 为 [handle] 创建轮询器。
  NetworkNativeIsolate(this.handle);

  final Pointer<Void> handle;
  final StreamController<Uint8List> _eventController =
      StreamController<Uint8List>.broadcast();
  ReceivePort? _receivePort;
  ReceivePort? _exitPort;
  Isolate? _worker;
  SendPort? _workerControlPort;
  bool _isPolling = false;

  /// 发布工作 isolate 收到的原始事件帧。
  Stream<Uint8List> get rawEvents => _eventController.stream;

  /// 启动工作 isolate 及其阻塞轮询循环。
  Future<void> startPolling({
    Duration interval = const Duration(milliseconds: 50),
  }) async {
    if (_isPolling || handle == nullptr) return;
    _isPolling = true;
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final controlPortReady = Completer<SendPort>();
    _receivePort = receivePort;
    _exitPort = exitPort;
    receivePort.listen((message) {
      if (message is Uint8List && !_eventController.isClosed) {
        _eventController.add(message);
      } else if (message is SendPort) {
        _workerControlPort = message;
        if (!controlPortReady.isCompleted) {
          controlPortReady.complete(message);
        }
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
      await controlPortReady.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      _isPolling = false;
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      receivePort.close();
      exitPort.close();
      _receivePort = null;
      _exitPort = null;
      _workerControlPort = null;
      rethrow;
    }
  }

  /// 通过原生 FFI 缓冲区边界发送一个命令。
  NativeOperationStatus sendCommand(Uint8List commandBytes) {
    if (handle == nullptr || commandBytes.isEmpty) {
      return NativeOperationStatus.invalidArgument;
    }

    final ptr = calloc<Uint8>(commandBytes.length);
    try {
      ptr.asTypedList(commandBytes.length).setAll(0, commandBytes);
      return NativeOperationStatus.fromNativeCode(
        _sshNetRuntimeCommandNative(handle, ptr, commandBytes.length),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  /// 关闭事件流前停止并等待工作 isolate 退出。
  Future<void> stop() async {
    if (!_isPolling && _worker == null) {
      if (!_eventController.isClosed) await _eventController.close();
      return;
    }
    _isPolling = false;
    final worker = _worker;
    final exitPort = _exitPort;
    if (worker != null && exitPort != null) {
      _workerControlPort?.send('stop');
      try {
        await exitPort.first.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        worker.kill(priority: Isolate.immediate);
      }
    }
    _worker = null;
    _workerControlPort = null;
    exitPort?.close();
    _exitPort = null;
    _receivePort?.close();
    _receivePort = null;
    if (!_eventController.isClosed) {
      await _eventController.close();
    }
  }
}

/// 在 helper isolate 上轮询原生事件，直到收到停止消息。
void _pollEvents(List<Object> arguments) {
  final handle = Pointer<Void>.fromAddress(arguments[0] as int);
  final events = arguments[1] as SendPort;
  final timeoutMs = arguments[2] as int;
  final controlPort = ReceivePort();
  var running = true;
  controlPort.listen((message) {
    if (message == 'stop') running = false;
  });
  events.send(controlPort.sendPort);

  unawaited(() async {
    while (running) {
      final outBuffer = calloc<SshNetBuffer>();
      try {
        final result = _NativePollStatus.fromNativeCode(
          _sshNetRuntimePollEventNative(handle, timeoutMs, outBuffer),
        );
        if (result == _NativePollStatus.eventAvailable) {
          final buffer = outBuffer.ref;
          if (buffer.ptr != nullptr) {
            if (buffer.len > 0) {
              events.send(
                Uint8List.fromList(buffer.ptr.asTypedList(buffer.len)),
              );
            }
            _sshNetBufferFreeNative(buffer);
          }
        } else if (result == _NativePollStatus.failure) {
          running = false;
        }
      } finally {
        calloc.free(outBuffer);
      }
      await Future<void>.delayed(Duration.zero);
    }
    controlPort.close();
  }());
}

/// 表示原生轮询函数的私有返回状态。
enum _NativePollStatus {
  noEvent,
  eventAvailable,
  failure;

  /// 将轮询函数的整数状态转换为私有类型。
  static _NativePollStatus fromNativeCode(int value) => switch (value) {
    1 => eventAvailable,
    0 => noEvent,
    _ => failure,
  };
}
