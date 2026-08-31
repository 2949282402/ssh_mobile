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
    this.traceId,
    this.eventName,
    this.errorCode,
    this.attributes = const {},
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

  /// 关联遥测 traceId（如有），便于诊断日志与事件流串联。
  final String? traceId;

  /// 关联遥测事件名（如有），便于诊断日志归属到具体埋点。
  final String? eventName;

  /// 关联遥测错误码（如有），与 `contracts/telemetry/error_codes.yaml` 对齐。
  final String? errorCode;

  /// 可选的附加键值属性。
  final Map<String, dynamic> attributes;

  /// 返回去额外元数据后的副本，供作用域日志转发时保留原始遥测上下文。
  LogRecord copyWith({
    String? source,
    String? details,
    Object? error,
    StackTrace? stackTrace,
    String? traceId,
    String? eventName,
    String? errorCode,
    Map<String, dynamic>? attributes,
    bool clearTraceContext = false,
  }) {
    return LogRecord(
      timestamp: timestamp,
      level: level,
      message: message,
      source: source ?? this.source,
      details: details ?? this.details,
      error: error ?? this.error,
      stackTrace: stackTrace ?? this.stackTrace,
      traceId: clearTraceContext ? null : (traceId ?? this.traceId),
      eventName: clearTraceContext ? null : (eventName ?? this.eventName),
      errorCode: clearTraceContext ? null : (errorCode ?? this.errorCode),
      attributes: attributes ?? this.attributes,
    );
  }
}
