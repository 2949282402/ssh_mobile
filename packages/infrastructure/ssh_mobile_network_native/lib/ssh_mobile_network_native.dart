// ssh_mobile_network_native package 的 v1 Dart 绑定与生命周期封装。
// 网络状态由 Rust 运行时拥有；Dart 只提交命令并轮询类型化线协议事件。

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/native_operation_status.dart';
import 'src/native_realtime_protocol.dart';
import 'src/network_native_isolate.dart';
export 'src/native_operation_status.dart';
export 'src/native_realtime_protocol.dart';

/// ssh_mobile_network_native 的 C ABI FFI 绑定。

/// 返回原生库导出的 v1 ABI 版本。
@Native<Uint32 Function()>(symbol: 'ssh_net_abi_version')
external int _sshNetAbiVersionNative();

/// 创建原生运行时句柄，并写入 [outHandle]。
@Native<Int32 Function(Pointer<Pointer<Void>>)>(
  symbol: 'ssh_net_runtime_create',
)
external int _sshNetRuntimeCreateNative(Pointer<Pointer<Void>> outHandle);

/// 启动已创建的原生运行时。
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_start')
external int _sshNetRuntimeStartNative(Pointer<Void> handle);

/// 停止正在运行的原生运行时。
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_stop')
external int _sshNetRuntimeStopNative(Pointer<Void> handle);

/// 销毁已停止的原生运行时句柄。
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_destroy')
external int _sshNetRuntimeDestroyNative(Pointer<Void> handle);

/// Dart 侧原生网络 SDK 操作的主入口。
class SshMobileNetworkNative {
  /// 创建无状态原生 SDK 外观。
  const SshMobileNetworkNative();

  /// 返回原生库报告的 ABI 版本。
  int getAbiVersion() => _sshNetAbiVersionNative();

  /// 创建并启动带事件轮询器的原生运行时。
  Future<NativeNetworkRuntime> createRuntime() async {
    final outHandle = calloc<Pointer<Void>>();
    try {
      final createResult = NativeOperationStatus.fromNativeCode(
        _sshNetRuntimeCreateNative(outHandle),
      );
      if (!createResult.isSuccess || outHandle.value == nullptr) {
        throw StateError(
          'Native network runtime creation failed (${createResult.name}).',
        );
      }
      final handle = outHandle.value;
      final startResult = NativeOperationStatus.fromNativeCode(
        _sshNetRuntimeStartNative(handle),
      );
      if (!startResult.isSuccess) {
        NativeOperationStatus.fromNativeCode(
          _sshNetRuntimeDestroyNative(handle),
        );
        throw StateError(
          'Native network runtime start failed (${startResult.name}).',
        );
      }
      final poller = NetworkNativeIsolate(handle);
      try {
        await poller.startPolling();
      } catch (_) {
        NativeOperationStatus.fromNativeCode(_sshNetRuntimeStopNative(handle));
        NativeOperationStatus.fromNativeCode(
          _sshNetRuntimeDestroyNative(handle),
        );
        rethrow;
      }
      return NativeNetworkRuntime._(handle, poller);
    } finally {
      calloc.free(outHandle);
    }
  }
}

/// 拥有已启动原生运行时及其 helper isolate 事件轮询器。
class NativeNetworkRuntime {
  /// 创建内部运行时封装。
  NativeNetworkRuntime._(this._handle, this._poller);

  Pointer<Void> _handle;
  final NetworkNativeIsolate _poller;
  int _commandSequence = 0;
  bool _stopped = false;

  /// 发布 helper isolate 收到的原始 v1 事件帧。
  Stream<Uint8List> get rawEvents => _poller.rawEvents;

  /// Typed native command/event stream. Unknown future events are ignored by
  /// the decoder; [rawEvents] remains available for protocol diagnostics.
  Stream<NativeNetworkEvent> get events => _poller.rawEvents
      .map(_decodeTypedEvent)
      .where((event) => event != null)
      .cast<NativeNetworkEvent>();

  /// 向原生运行时提交一个已编码命令。
  NativeOperationStatus sendCommand(Uint8List command) {
    if (_handle == nullptr || _stopped) return NativeOperationStatus.stopped;
    return _poller.sendCommand(command);
  }

  /// Starts a Session-owned WebRTC Realtime route.
  NativeOperationStatus startRealtimeSession({
    required String realtimeId,
    required String peerId,
  }) {
    try {
      return sendCommand(
        NativeNetworkProtocol.startRealtimeSessionCommand(
          commandId: _nextCommandId('realtime-start'),
          realtimeId: realtimeId,
          peerId: peerId,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  /// Stops a Session-owned WebRTC Realtime route.
  NativeOperationStatus stopRealtimeSession({required String realtimeId}) {
    try {
      return sendCommand(
        NativeNetworkProtocol.stopRealtimeSessionCommand(
          commandId: _nextCommandId('realtime-stop'),
          realtimeId: realtimeId,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  /// Sends a bounded SDP/ICE/close signal through the native control plane.
  NativeOperationStatus sendRealtimeSignal({
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) {
    try {
      return sendCommand(
        NativeNetworkProtocol.sendRealtimeSignalCommand(
          commandId: _nextCommandId('realtime-signal'),
          realtimeId: realtimeId,
          peerId: peerId,
          kind: kind,
          revision: revision,
          payload: payload,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  /// 在停止原生运行时前停止 helper isolate。
  Future<NativeOperationStatus> stop() async {
    if (_handle == nullptr || _stopped) return NativeOperationStatus.success;
    _stopped = true;
    await _poller.stop();
    return NativeOperationStatus.fromNativeCode(
      _sshNetRuntimeStopNative(_handle),
    );
  }

  /// 恰好执行一次运行时停止和销毁。
  Future<void> dispose() async {
    final handle = _handle;
    if (handle == nullptr) return;
    final stopResult = await stop();
    _handle = nullptr;
    if (!stopResult.isSuccess) {
      throw StateError(
        'Native network runtime stop failed (${stopResult.name}).',
      );
    }
    final result = NativeOperationStatus.fromNativeCode(
      _sshNetRuntimeDestroyNative(handle),
    );
    if (!result.isSuccess) {
      throw StateError(
        'Native network runtime destroy failed (${result.name}).',
      );
    }
  }

  String _nextCommandId(String operation) {
    _commandSequence = (_commandSequence + 1) & 0x7fffffff;
    return '$operation-${DateTime.now().microsecondsSinceEpoch}-$_commandSequence';
  }

  static NativeNetworkEvent? _decodeTypedEvent(Uint8List bytes) {
    try {
      return NativeNetworkProtocol.decodeEvent(bytes);
    } on FormatException {
      return null;
    }
  }
}
