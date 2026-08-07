import '../lifecycle/disposable.dart';
import 'app_logger.dart';
import 'log_buffer.dart';
import 'log_record.dart';
import 'log_sink.dart';
import 'scoped_logger.dart';

/// Core 提供的轻量 Logger 实现。
///
/// 该实现只负责有界内存缓冲和同步分发到 Sink，不依赖 Flutter、Drift
/// 或平台文件 API。App 层若需要 UI 通知、脱敏或数据库绑定，应通过
/// 自己的适配器实现 [AppLogger]，而不是把这些职责反向放入 Core。
final class AppLoggerImpl implements AppLogger, Disposable {
  /// 创建一个带有有界内存缓冲区的 Logger。
  AppLoggerImpl({
    Iterable<LogSink> sinks = const [],
    int maxEntries = LogBuffer.defaultMaxEntries,
  }) : buffer = LogBuffer<LogRecord>(maxEntries: maxEntries),
       _sinks = List<LogSink>.unmodifiable(sinks);

  /// 当前 Logger 的内存日志缓冲区。
  final LogBuffer<LogRecord> buffer;
  final List<LogSink> _sinks;
  bool _disposed = false;

  /// 当前 Logger 是否已经释放。
  bool get isDisposed => _disposed;

  /// 按顺序写入内存缓冲区并分发给所有 Sink。
  @override
  void log(LogRecord record) {
    if (_disposed) return;
    buffer.add(record);
    for (final sink in _sinks) {
      sink.write(record);
    }
  }

  /// 返回只改变作用域、不改变所有权的日志视图。
  @override
  AppLogger scope(String name) {
    return ScopedLogger(this, name);
  }

  /// 先关闭全部 Sink，再标记 Logger 已释放；重复调用是幂等的。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    Object? firstError;
    StackTrace? firstStackTrace;
    for (final sink in _sinks) {
      try {
        await sink.close();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}
