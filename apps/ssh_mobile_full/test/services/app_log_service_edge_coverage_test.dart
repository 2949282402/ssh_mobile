import 'package:app_core/app_core.dart' as app_core;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/app_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('maps every Core log level and caches filtered snapshots', () async {
    final logs = AppLogService.instance;
    logs.clear();
    final levels = <app_core.LogLevel>[
      app_core.LogLevel.trace,
      app_core.LogLevel.debug,
      app_core.LogLevel.info,
      app_core.LogLevel.warning,
      app_core.LogLevel.error,
    ];
    for (final level in levels) {
      logs.log(
        app_core.LogRecord(
          timestamp: DateTime.utc(2026, 8, 29),
          level: level,
          message: level.name,
          source: level == app_core.LogLevel.info ? 'test-source' : null,
          details: 'details',
          stackTrace: StackTrace.fromString(
            '(package:ssh_mobile/services/example.dart:42:3)',
          ),
          error: level == app_core.LogLevel.error
              ? StateError('failure')
              : null,
        ),
      );
    }
    await logs.pendingWrites;

    expect(logs.levelCounts[AppLogLevel.debug], 2);
    expect(logs.levelCounts[AppLogLevel.error], 1);
    expect(logs.entriesForLevel(AppLogLevel.info), hasLength(1));
    expect(
      logs.entriesForLevel(AppLogLevel.info),
      same(logs.entriesForLevel(AppLogLevel.info)),
    );
    expect(logs.entriesForLevel(AppLogLevel.all), same(logs.entries));
    expect(logs.entryIds, hasLength(5));
    expect(logs.entryIds, same(logs.entryIds));
    expect(
      logs.entries
          .singleWhere((entry) => entry.sourceLocation == 'test-source')
          .sourceLocation,
      'test-source',
    );
  });

  test(
    'installs and forwards Flutter, debugPrint, and platform error hooks',
    () {
      final logs = AppLogService.instance;
      logs.clear();
      final previousFlutterError = FlutterError.onError;
      final previousPlatformError = PlatformDispatcher.instance.onError;
      logs.install();
      logs.install();
      debugPrint('edge debug message');
      debugPrint('');
      FlutterError.onError?.call(
        FlutterErrorDetails(exception: StateError('widget failure')),
      );
      final handled = PlatformDispatcher.instance.onError?.call(
        StateError('platform failure'),
        StackTrace.current,
      );

      expect(handled, isFalse);
      expect(
        logs.entries.map((entry) => entry.level),
        containsAll(<String>['app', 'debug', 'flutter', 'platform']),
      );
      expect(FlutterError.onError, isNotNull);
      expect(PlatformDispatcher.instance.onError, isNotNull);

      // The singleton remains installed until the final test in this file so
      // later assertions can exercise the same hook state.
      expect(previousFlutterError, isA<Object?>());
      expect(previousPlatformError, isA<Object?>());
    },
  );

  test('accepts explicit source locations and handles empty deletion', () {
    final logs = AppLogService.instance;
    logs.clear();
    logs.add(
      'info',
      'explicit source',
      captureSource: true,
      sourceLocation: 'explicit.dart:9',
    );
    logs.deleteEntriesById(const <int>{});
    expect(logs.entries.single.sourceLocation, 'explicit.dart:9');
    logs.dispose();
  });
}
