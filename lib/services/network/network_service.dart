// v1 原生网络服务，负责将命令确认与 FFI 事件关联，
// 并只向 Flutter 暴露类型化的 NetworkResult/NetworkEvent。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:uuid/uuid.dart';

import 'network_models.dart';
import 'network_protocol_codec.dart';

/// 将原生 v1 运行时适配为 Flutter 的类型化网络契约。
final class NativeNetworkService implements NetworkService {
  /// 基于已创建的原生运行时创建服务。
  NativeNetworkService(this._runtime, {NetworkProtocolCodec? codec})
    : _codec = codec ?? const NetworkProtocolCodec() {
    _nativeSubscription = _runtime.rawEvents.listen(_handleNativeEvent);
  }

  final NativeNetworkRuntime _runtime;
  final NetworkProtocolCodec _codec;
  final StreamController<NetworkEvent> _eventController =
      StreamController<NetworkEvent>.broadcast();
  final Map<String, _PendingNetworkCommand> _pendingCommands =
      <String, _PendingNetworkCommand>{};
  final Map<String, String> _transferPeers = <String, String>{};
  final Map<String, NetworkRouteType> _peerRoutes =
      <String, NetworkRouteType>{};
  final Map<String, RouteSnapshot> _routes = <String, RouteSnapshot>{};
  late final StreamSubscription<Uint8List> _nativeSubscription;
  bool _configured = false;
  bool _stopped = false;
  bool _disposed = false;

  /// 消费内部命令结果后发布公开的类型化事件。
  @override
  Stream<NetworkEvent> get events => _eventController.stream;

  /// 启动原生运行时，并等待对应的命令结果事件。
  @override
  Future<NetworkResult<void>> start(NetworkRuntimeConfig config) async {
    _ensureUsable();
    if (_stopped) return _cancelled(NetworkOperation.start);
    if (_configured) return const NetworkSuccess<void>(null);
    final result = await _submit(
      _codec.configureRuntimeCommand(
        commandId: const Uuid().v4(),
        config: config,
      ),
      operation: NetworkOperation.start,
      timeout: const Duration(seconds: 15),
    );
    if (result is NetworkSuccess<void>) _configured = true;
    return result;
  }

  /// 停止原生运行时，并关闭公开事件流。
  @override
  Future<NetworkResult<void>> stop() async {
    _ensureUsable();
    if (_stopped) return const NetworkSuccess<void>(null);
    _stopped = true;
    for (final pending in _pendingCommands.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(_cancelled(NetworkOperation.stop));
      }
    }
    _pendingCommands.clear();
    final status = await _runtime.stop();
    if (!status.isSuccess) {
      return _failure(
        _nativeStatusError(status, operation: NetworkOperation.stop),
      );
    }
    await _nativeSubscription.cancel();
    if (!_eventController.isClosed) await _eventController.close();
    return const NetworkSuccess<void>(null);
  }

  /// 在原生运行时新增或替换对端。
  @override
  Future<NetworkResult<void>> upsertPeer(PeerConfig peer) {
    return _submit(
      _codec.upsertPeerCommand(commandId: const Uuid().v4(), peer: peer),
      operation: NetworkOperation.upsertPeer,
    );
  }

  /// 接受对端连接任务，并等待命令确认。
  @override
  Future<NetworkResult<void>> connect(String peerId) {
    _ensureUsable();
    if (peerId.trim().isEmpty) {
      return Future.value(
        _failure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'peer_id is required',
            operation: NetworkOperation.connect,
          ),
        ),
      );
    }
    return _submit(
      _codec.connectPeerCommand(commandId: const Uuid().v4(), peerId: peerId),
      operation: NetworkOperation.connect,
      timeout: const Duration(seconds: 12),
    );
  }

  /// 接受对端断开任务，并等待命令确认。
  @override
  Future<NetworkResult<void>> disconnect(String peerId) {
    _ensureUsable();
    if (peerId.trim().isEmpty) {
      return Future.value(
        _failure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'peer_id is required',
            operation: NetworkOperation.disconnect,
          ),
        ),
      );
    }
    return _submit(
      _codec.disconnectPeerCommand(
        commandId: const Uuid().v4(),
        peerId: peerId,
      ),
      operation: NetworkOperation.disconnect,
    );
  }

  /// 配置原生 Relay 数据面。
  @override
  Future<NetworkResult<void>> configureRelay(RelayConfig config) {
    return _submit(
      _codec.configureRelayCommand(
        commandId: const Uuid().v4(),
        config: config,
      ),
      operation: NetworkOperation.configureRelay,
      timeout: const Duration(seconds: 15),
    );
  }

  /// 请求断开原生 Relay。
  @override
  Future<NetworkResult<void>> disconnectRelay() {
    return _submit(
      _codec.disconnectRelayCommand(commandId: const Uuid().v4()),
      operation: NetworkOperation.disconnectRelay,
    );
  }

  /// 注册源文件传输，并返回已接受的传输会话。
  @override
  Future<NetworkResult<TransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async {
    _ensureUsable();
    if (transferId.trim().isEmpty || peerId.trim().isEmpty) {
      return _failure(
        const NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'transfer_id and peer_id are required',
          operation: NetworkOperation.send,
        ),
      );
    }
    final file = File(filePath);
    if (!await file.exists()) {
      return _failure(
        const NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'source file is unavailable',
          operation: NetworkOperation.send,
        ),
      );
    }
    final absolutePath = file.absolute.path;
    _transferPeers[transferId] = peerId;
    final result = await _submit(
      _codec.sendFileCommand(
        commandId: const Uuid().v4(),
        transferId: transferId,
        peerId: peerId,
        filePath: absolutePath,
      ),
      operation: NetworkOperation.send,
    );
    if (result is NetworkFailure<void>) _transferPeers.remove(transferId);
    if (result is NetworkFailure<void>) return _failure(result.error);
    return NetworkSuccess(
      TransferSession(
        transferId: transferId,
        peerId: peerId,
        filePath: absolutePath,
        routeType: _peerRoutes[peerId] ?? NetworkRouteType.unspecified,
      ),
    );
  }

  /// 请求取消已接受的传输。
  @override
  Future<NetworkResult<void>> cancel(String transferId) {
    _ensureUsable();
    if (transferId.trim().isEmpty) {
      return Future.value(
        _failure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'transfer_id is required',
            operation: NetworkOperation.cancel,
          ),
        ),
      );
    }
    return _submit(
      _codec.cancelTransferCommand(
        commandId: const Uuid().v4(),
        transferId: transferId,
      ),
      operation: NetworkOperation.cancel,
    );
  }

  /// 接受或拒绝原生传入传输申请。
  @override
  Future<NetworkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) {
    _ensureUsable();
    return _submit(
      _codec.respondIncomingTransferCommand(
        commandId: const Uuid().v4(),
        transferId: transferId,
        accept: accept,
      ),
      operation: NetworkOperation.respondToIncoming,
    );
  }

  /// 返回最近观察到的 [peerId] 类型化路由快照。
  @override
  Future<NetworkResult<RouteSnapshot>> state(String peerId) async {
    _ensureUsable();
    if (peerId.trim().isEmpty) {
      return _failure(
        const NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'peer_id is required',
          operation: NetworkOperation.state,
        ),
      );
    }
    final route = _routes[peerId];
    if (route == null) {
      return _failure(
        NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'peer route is not available',
          operation: NetworkOperation.state,
          peerId: peerId,
        ),
      );
    }
    return NetworkSuccess(route);
  }

  /// 发送命令，并等待对应的内部命令结果事件。
  Future<NetworkResult<void>> _submit(
    Uint8List command, {
    required NetworkOperation operation,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    _ensureUsable();
    if (_stopped) return _cancelled(operation);
    final commandId = _codec.commandId(command);
    final pending = _PendingNetworkCommand(
      completer: Completer<NetworkResult<void>>(),
      operation: operation,
    );
    _pendingCommands[commandId] = pending;
    final status = _runtime.sendCommand(command);
    if (!status.isSuccess) {
      _pendingCommands.remove(commandId);
      return _failure(_nativeStatusError(status, operation: operation));
    }
    try {
      return await pending.completer.future.timeout(
        timeout,
        onTimeout: () => _failure(
          NetworkError(
            code: NetworkErrorCode.timeout,
            message: 'network command acceptance timed out',
            operation: operation,
          ),
        ),
      );
    } finally {
      _pendingCommands.remove(commandId);
    }
  }

  /// 解码一个原生事件，并将其路由到待完成命令或公开事件流。
  void _handleNativeEvent(Uint8List bytes) {
    try {
      final frame = _codec.decodeEvent(bytes);
      if (frame.protocolVersion != NetworkProtocolCodec.protocolVersion) {
        return;
      }
      final commandId = frame.commandId;
      if (commandId != null) {
        final pending = _pendingCommands[commandId];
        if (pending == null || pending.completer.isCompleted) return;
        if (frame.commandAccepted) {
          pending.completer.complete(const NetworkSuccess<void>(null));
        } else {
          pending.completer.complete(
            _failure(
              _commandErrorForOperation(frame.commandError, pending.operation),
            ),
          );
        }
        return;
      }
      final event = frame.event;
      if (event == null || _eventController.isClosed) return;
      if (event case PeerStateChanged(
        :final peerId,
        :final state,
        :final routeType,
      )) {
        if (state == PeerConnectionState.connected) {
          _peerRoutes[peerId] = routeType;
          _routes[peerId] = RouteSnapshot(peerId: peerId, routeType: routeType);
        } else if (state == PeerConnectionState.disconnected ||
            state == PeerConnectionState.failed) {
          _peerRoutes.remove(peerId);
          _routes.remove(peerId);
        }
      } else if (event case RouteChanged(:final snapshot)) {
        _peerRoutes[snapshot.peerId] = snapshot.routeType;
        _routes[snapshot.peerId] = snapshot;
      } else if (event case IncomingTransferOffer(
        :final transferId,
        :final peerId,
      )) {
        _transferPeers[transferId] = peerId;
      } else if (event
          case TransferCompleted(:final transferId) ||
              TransferFailed(:final transferId)) {
        _transferPeers.remove(transferId);
      }
      _eventController.add(event);
    } on FormatException {
      // 格式错误的原生帧在事件边界被忽略。待完成调用只能由原生命令结果完成。
    }
  }

  /// 将原生整数状态转换为安全的结构化错误。
  NetworkError _nativeStatusError(
    NativeOperationStatus status, {
    required NetworkOperation operation,
  }) {
    final code = switch (status) {
      NativeOperationStatus.invalidArgument => NetworkErrorCode.invalidArgument,
      NativeOperationStatus.stopped => NetworkErrorCode.cancelled,
      _ => NetworkErrorCode.ioError,
    };
    return NetworkError(
      code: code,
      message: 'native network runtime rejected the command',
      operation: operation,
    );
  }

  /// 创建运行时停止后使用的标准结果。
  NetworkFailure<void> _cancelled(NetworkOperation operation) => _failure(
    NetworkError(
      code: NetworkErrorCode.cancelled,
      message: 'network runtime is stopped',
      operation: operation,
    ),
  );

  /// 将错误包装为类型化失败结果。
  NetworkFailure<T> _failure<T>(NetworkError error) => NetworkFailure(error);

  /// 为内部命令错误补齐稳定的操作上下文。
  NetworkError _commandErrorForOperation(
    NetworkError? error,
    NetworkOperation operation,
  ) {
    final resolved =
        error ??
        const NetworkError(
          code: NetworkErrorCode.unspecified,
          message: 'network command was rejected',
        );
    return resolved.copyWith(operation: resolved.operation ?? operation);
  }

  /// 抛出 API 允许的唯一服务生命周期异常。
  void _ensureUsable() {
    if (_disposed) throw const NetworkServiceDisposedException();
  }

  /// 销毁 Dart 服务及其底层原生运行时。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_stopped) {
      _stopped = true;
      for (final pending in _pendingCommands.values) {
        if (!pending.completer.isCompleted) {
          pending.completer.complete(_cancelled(NetworkOperation.stop));
        }
      }
      _pendingCommands.clear();
      await _nativeSubscription.cancel();
      await _runtime.dispose();
    } else {
      await _nativeSubscription.cancel();
      await _runtime.dispose();
    }
    if (!_eventController.isClosed) await _eventController.close();
  }
}

/// 关联一个内部 commandId 与其公开操作结果上下文。
/// 关联一个内部 commandId 与其公开操作结果上下文。
final class _PendingNetworkCommand {
  /// 创建带操作上下文的待完成命令。
  /// 创建带操作上下文的待完成命令。
  _PendingNetworkCommand({required this.completer, required this.operation});

  /// 等待原生 CommandResultEvent 的结果。
  final Completer<NetworkResult<void>> completer;

  /// 用于补齐服务端错误的公开操作。
  /// 用于补齐服务端错误的公开操作。
  final NetworkOperation operation;
}
