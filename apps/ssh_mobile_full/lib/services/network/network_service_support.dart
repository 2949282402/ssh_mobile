part of 'network_service.dart';

/// App Shell 服务的共享生命周期状态；具体资源由各端口分别释放。
final class _NetworkServiceState {
  bool configured = false;
  bool stopped = false;
  bool disposed = false;

  void ensureUsable() {
    if (disposed) throw const NetworkServiceDisposedException();
  }
}

/// 将错误包装为稳定的 typed failure。
NetworkFailure<T> _networkFailure<T>(NetworkError error) =>
    NetworkFailure<T>(error);

/// 创建运行时停止后使用的标准结果。
NetworkFailure<void> _networkCancelled(NetworkOperation operation) =>
    _networkFailure(
      NetworkError(
        code: NetworkErrorCode.cancelled,
        message: 'network runtime is stopped',
        operation: operation,
      ),
    );

/// 将原生整数状态转换为安全的结构化错误。
NetworkError _networkNativeStatusError(
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

/// 将共享 gateway 的传输状态转换为稳定的网络错误。
NetworkError _networkTransportStatusError(
  TransportOperationStatus status, {
  required NetworkOperation operation,
}) {
  final code = switch (status) {
    TransportOperationStatus.invalidArgument =>
      NetworkErrorCode.invalidArgument,
    TransportOperationStatus.stopped => NetworkErrorCode.cancelled,
    _ => NetworkErrorCode.ioError,
  };
  return NetworkError(
    code: code,
    message: 'network command gateway rejected the command',
    operation: operation,
  );
}

/// 为内部命令错误补齐稳定的操作上下文。
NetworkError _networkCommandErrorForOperation(
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
