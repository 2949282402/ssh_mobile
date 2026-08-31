import 'network_error_models.dart';

/// SDK 客户端操作的 typed result。
sealed class SdkResult<T> {
  const SdkResult();

  bool get isSuccess => this is SdkSuccess<T>;
}

final class SdkSuccess<T> extends SdkResult<T> {
  const SdkSuccess(this.data);

  final T data;
}

final class SdkFailure<T> extends SdkResult<T> {
  const SdkFailure(this.error);

  final NetworkError error;
}

/// SDK facade 释放后继续调用的稳定异常。
final class SdkClientDisposedException implements Exception {
  const SdkClientDisposedException();

  @override
  String toString() => 'SdkClientDisposedException';
}
