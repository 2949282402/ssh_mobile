import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  test('formats log text with optional fields and normalizes levels', () {
    final entry = AppLogEntry(
      id: 1,
      time: DateTime(2026, 1, 2, 3, 4, 5, 6),
      level: 'WARNING',
      message: 'message',
      sourceLocation: 'source',
      stackTrace: 'stack',
      details: 'details',
    );

    expect(entry.text, contains('03:04:05.006 [WARNING] message'));
    expect(entry.text, contains('source: source'));
    expect(entry.text, contains('details'));
    expect(entry.text, contains('stack'));
    expect(entry.normalizedLevel, AppLogLevel.warning);

    final minimal = AppLogEntry(
      id: 2,
      time: DateTime(2026, 1, 2),
      level: 'unknown',
      message: 'minimal',
      sourceLocation: '',
      stackTrace: null,
      details: '',
    );
    expect(minimal.text, isNot(contains('source:')));
    expect(minimal.normalizedLevel, AppLogLevel.info);
  });

  test('labels every log level in both supported languages', () {
    for (final level in AppLogLevel.values) {
      expect(level.name, isNotEmpty);
      expect(level.englishLabel, isNotEmpty);
      expect(level.chineseLabel, isNotEmpty);
      expect(level.labelFor(AppLanguage.en), level.englishLabel);
      expect(level.labelFor(AppLanguage.zh), level.chineseLabel);
      expect(AppLogLevel.fromName(level.name), level);
    }
    expect(AppLogLevel.fromName(' INFO '), AppLogLevel.info);
  });
}
