import 'log_level.dart';

/// 一条不可变的日志记录值对象。
///
/// 该类型只承载日志契约，不负责持久化、脱敏、UI 通知或输出到具体平台；
/// 这些行为继续由 App Scope 的日志实现负责。
final class LogRecord {
  /// 创建一条日志记录。
  const LogRecord({
    required this.timestamp,
    required this.level,
    required this.message,
    this.source,
    this.details,
    this.error,
    this.stackTrace,
  });

  /// 记录产生的时间。
  final DateTime timestamp;

  /// 记录的严重级别。
  final LogLevel level;

  /// 面向日志阅读者的主要消息。
  final String message;

  /// 产生记录的模块或组件标识。
  final String? source;

  /// 可选的补充诊断信息。
  final String? details;

  /// 可选的原始错误对象。
  final Object? error;

  /// 可选的错误堆栈。
  final StackTrace? stackTrace;
}
