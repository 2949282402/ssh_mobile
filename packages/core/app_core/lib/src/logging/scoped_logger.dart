import 'app_logger.dart';
import 'log_record.dart';

/// 为某个模块提供带作用域的日志视图。
///
/// ScopedLogger 不复制或拥有底层 Logger，只在转发前把作用域写入
/// [LogRecord.source]。嵌套作用域使用 `/` 连接，便于统一过滤和检索。
final class ScopedLogger implements AppLogger {
  /// 创建一个委托给 [delegate] 的作用域 Logger。
  ScopedLogger(this._delegate, String scope)
    : scopeName = _normalizeScope(scope);

  final AppLogger _delegate;

  /// 当前作用域名称。
  final String scopeName;

  /// 转发带当前作用域的记录。
  @override
  void log(LogRecord record) {
    final source = record.source == null || record.source!.isEmpty
        ? scopeName
        : '$scopeName/${record.source}';
    _delegate.log(
      record.copyWith(source: source),
    );
  }

  /// 创建嵌套作用域，底层 Logger 仍由根 Logger 统一拥有。
  @override
  AppLogger scope(String name) {
    return ScopedLogger(_delegate, '$scopeName/${_normalizeScope(name)}');
  }

  static String _normalizeScope(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'scope', '日志作用域不能为空');
    }
    return normalized;
  }
}
