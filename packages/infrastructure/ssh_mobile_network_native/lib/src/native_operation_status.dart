// Native network status 的 Dart 类型化表示。
//
// C ABI 仍使用整数返回值，但整数只在本文件的转换边界出现，
// package 公共 API 和 Flutter 业务代码只接触此枚举。

/// 描述一次原生网络操作的安全结果状态。
enum NativeOperationStatus {
  success,
  invalidArgument,
  stopped,
  failure;

  /// 将 C ABI 整数状态转换为 Dart 类型。
  static NativeOperationStatus fromNativeCode(int value) => switch (value) {
    0 => success,
    -1 || -2 => invalidArgument,
    -4 => stopped,
    _ => failure,
  };

  /// 返回当前状态是否表示操作已成功完成。
  bool get isSuccess => this == success;
}
