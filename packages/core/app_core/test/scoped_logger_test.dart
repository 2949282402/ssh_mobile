import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ScopedLogger 将作用域写入 source', () {
    final logger = _RecordingLogger();
    final terminalLogger = logger.scope(' terminal ');

    terminalLogger.log(
      LogRecord(
        timestamp: DateTime.utc(2026, 8, 7),
        level: LogLevel.info,
        message: 'connected',
      ),
    );

    expect(logger.records.single.source, 'terminal');
  });

  test('ScopedLogger 支持嵌套作用域并保留记录字段', () {
    final logger = _RecordingLogger();
    final nestedLogger = logger.scope('ssh').scope('session');
    final record = LogRecord(
      timestamp: DateTime.utc(2026, 8, 7),
      level: LogLevel.error,
      message: 'failed',
      source: 'socket',
      details: 'details',
    );

    nestedLogger.log(record);

    expect(logger.records.single.source, 'ssh/session/socket');
    expect(logger.records.single.message, record.message);
    expect(logger.records.single.details, record.details);
  });
}

final class _RecordingLogger implements AppLogger {
  final records = <LogRecord>[];

  @override
  void log(LogRecord record) => records.add(record);

  @override
  AppLogger scope(String name) => ScopedLogger(this, name);
}
