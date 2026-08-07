import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppLoggerImpl 使用有界缓冲并将记录写入 Sink', () async {
    final sink = _RecordingSink();
    final logger = AppLoggerImpl(sinks: [sink], maxEntries: 2);

    logger
      ..log(_record('one'))
      ..log(_record('two'))
      ..log(_record('three'));

    expect(logger.buffer.newestFirst.map((record) => record.message), [
      'three',
      'two',
    ]);
    expect(sink.records.map((record) => record.message), [
      'one',
      'two',
      'three',
    ]);

    await logger.dispose();
    expect(sink.closeCount, 1);
    logger.log(_record('ignored after dispose'));
    expect(sink.records, hasLength(3));

    await logger.dispose();
    expect(sink.closeCount, 1);
  });
}

LogRecord _record(String message) {
  return LogRecord(
    timestamp: DateTime.utc(2026, 8, 7),
    level: LogLevel.info,
    message: message,
  );
}

final class _RecordingSink implements LogSink {
  final records = <LogRecord>[];
  int closeCount = 0;

  @override
  void write(LogRecord record) => records.add(record);

  @override
  Future<void> close() async {
    closeCount++;
  }
}
