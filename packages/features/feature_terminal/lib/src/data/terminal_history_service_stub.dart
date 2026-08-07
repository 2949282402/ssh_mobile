// 非 IO 平台的 Terminal 输出历史安全空实现。

import '../domain/terminal_ports.dart';

/// Web 等平台不落地原始终端输出，避免绕过平台文件和密钥策略。
class TerminalHistoryService {
  /// 创建空实现；参数保持与 IO 实现一致，便于依赖注入。
  TerminalHistoryService({
    required TerminalHistoryOutputProtector dataProtection,
    required TerminalLoggerPort logger,
    Object? historyDirectoryProvider,
  });

  /// 默认输出历史加载上限。
  static const int defaultLoadBytes = 2 * 1024 * 1024;

  /// 追加输出；非 IO 平台忽略数据。
  Future<void> append(String sessionId, String data) async {}

  /// 读取输出尾部；非 IO 平台始终返回空字符串。
  Future<String> readTail(
    String sessionId, {
    int maxBytes = defaultLoadBytes,
  }) async => '';

  /// 返回平台历史文件句柄；非 IO 平台没有文件。
  Future<Object?> historyFile(String sessionId) async => null;

  /// 等待输出写入；非 IO 平台无需等待。
  Future<void> flush() async {}

  /// 释放资源；空实现保持幂等。
  Future<void> dispose() async {}
}
