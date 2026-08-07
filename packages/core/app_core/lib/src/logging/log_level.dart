/// Core 日志合约使用的严重级别。
///
/// 业务分类（例如 Flutter、Platform 或 Service）不放入 Core 的级别枚举，
/// 具体实现可通过 LogRecord.source 或上层元数据表达，避免 Core 反向依赖业务。
enum LogLevel {
  /// 细粒度诊断信息。
  trace,

  /// 开发调试信息。
  debug,

  /// 常规运行信息。
  info,

  /// 非致命异常或降级信息。
  warning,

  /// 需要处理的错误。
  error,
}
