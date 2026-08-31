part of 'network_service.dart';

/// 命令执行端口：拥有 commandId 等待表和 gateway 结果确认。
final class _NetworkCommandCoordinator {
  _NetworkCommandCoordinator({
    required this.gateway,
    required this.codec,
    required this.state,
    this.traceRegistry,
  });

  final NetworkCommandGateway gateway;
  final NetworkProtocolV2Codec codec;
  final _NetworkServiceState state;
  final TelemetryTraceRegistry? traceRegistry;
  final Map<String, _PendingNetworkCommand> _pendingCommands =
      <String, _PendingNetworkCommand>{};

  void ensureUsable() => state.ensureUsable();

  /// 发送命令并等待对应的内部命令结果事件。
  Future<NetworkResult<void>> submit(
    Uint8List command, {
    required NetworkOperation operation,
    Duration timeout = const Duration(seconds: 3),
    String? peerId,
  }) async {
    state.ensureUsable();
    if (state.stopped) return _networkCancelled(operation);
    final commandId = codec.commandId(command);
    if (_pendingCommands.containsKey(commandId)) {
      return _networkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'native command id is already pending',
          operation: operation,
        ),
      );
    }
    final pending = _PendingNetworkCommand(
      completer: Completer<NetworkResult<void>>(),
      operation: operation,
    );
    _pendingCommands[commandId] = pending;
    final traceId = peerId == null ? null : traceRegistry?.traceForPeer(peerId);
    if (peerId != null && traceId != null) {
      traceRegistry?.bindCommand(
        commandId: commandId,
        peerId: peerId,
        traceId: traceId,
      );
    }
    final status = gateway.sendCommand(command);
    if (status != TransportOperationStatus.success) {
      _pendingCommands.remove(commandId);
      traceRegistry?.completeCommand(commandId);
      return _networkFailure(
        _networkTransportStatusError(status, operation: operation),
      );
    }
    NetworkResult<void>? result;
    try {
      result = await pending.completer.future.timeout(
        timeout,
        onTimeout: () => _networkFailure(
          NetworkError(
            code: NetworkErrorCode.timeout,
            message: 'network command acceptance timed out',
            operation: operation,
          ),
        ),
      );
      return result;
    } finally {
      _pendingCommands.remove(commandId);
      traceRegistry?.completeCommand(
        commandId,
        retainPeerBinding:
            operation == NetworkOperation.connect &&
            result is NetworkSuccess<void>,
      );
    }
  }

  /// 解码并消费一个 native frame；非命令 frame 返回给事件路由器。
  NetworkProtocolFrame? handleNativeFrame(Uint8List bytes) {
    final frame = codec.decodeEvent(bytes);
    if (frame.protocolVersion != NetworkProtocolV2Codec.protocolVersion) {
      return null;
    }
    final commandId = frame.commandId;
    if (commandId == null) return frame;
    final pending = _pendingCommands[commandId];
    if (pending == null || pending.completer.isCompleted) return null;
    if (frame.commandAccepted) {
      pending.completer.complete(const NetworkSuccess<void>(null));
    } else {
      pending.completer.complete(
        _networkFailure(
          _networkCommandErrorForOperation(
            frame.commandError,
            pending.operation,
          ),
        ),
      );
    }
    return null;
  }

  /// 在 stop/dispose 边界完成全部尚未确认的命令。
  void cancelPending({NetworkOperation operation = NetworkOperation.stop}) {
    final commandIds = _pendingCommands.keys.toList(growable: false);
    for (final pending in _pendingCommands.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(_networkCancelled(operation));
      }
    }
    _pendingCommands.clear();
    for (final commandId in commandIds) {
      traceRegistry?.completeCommand(commandId);
    }
  }
}

/// 关联一个内部 commandId 与其公开操作结果上下文。
final class _PendingNetworkCommand {
  _PendingNetworkCommand({required this.completer, required this.operation});

  final Completer<NetworkResult<void>> completer;
  final NetworkOperation operation;
}
