import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LogRecord 保留 Core 日志契约字段', () {
    final record = LogRecord(
      timestamp: DateTime.utc(2026, 8, 7),
      level: LogLevel.error,
      message: 'failure',
      source: 'test',
      details: 'details',
      error: StateError('error'),
      stackTrace: StackTrace.current,
    );
    final logger = _RecordingLogger();

    logger.log(record);

    expect(logger.records.single, same(record));
    expect(record.level, LogLevel.error);
    expect(record.source, 'test');
  });
}

final class _RecordingLogger implements AppLogger {
  final records = <LogRecord>[];

  @override
  void log(LogRecord record) {
    records.add(record);
  }
}
