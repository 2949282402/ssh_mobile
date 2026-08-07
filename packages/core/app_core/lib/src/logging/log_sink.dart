import 'log_record.dart';

/// 日志输出端的最小契约。
///
/// Sink 只接收已经形成的 [LogRecord]，不负责决定日志是否进入内存；
/// [close] 由拥有该 Sink 的 Logger 在 App Scope 结束时调用，以便关闭
/// 文件、数据库或其他异步输出资源。
abstract interface class LogSink {
  /// 接收一条日志记录。
  void write(LogRecord record);

  /// 释放 Sink 持有的输出资源。
  Future<void> close();
}
