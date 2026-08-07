import 'log_record.dart';

/// App Scope 日志实现必须提供的最小接口。
///
/// Core 只依赖这个合约，不创建全局 Logger，也不规定内存、数据库、磁盘
/// 或平台输出策略；具体实现由 AppRuntime 通过依赖注入提供。
abstract interface class AppLogger {
  /// 接收一条日志记录。
  void log(LogRecord record);
}
