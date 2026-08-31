import 'dart:io';

import 'package:app_core/app_core.dart' as app_core;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

final class _RecordingLogSink implements app_core.LogSink {
  final List<app_core.LogRecord> records = <app_core.LogRecord>[];

  @override
  void write(app_core.LogRecord record) {
    records.add(record);
  }

  @override
  Future<void> close() async {}
}

final class _ThrowingLogSink implements app_core.LogSink {
  @override
  void write(app_core.LogRecord record) {
    throw StateError('sink failure');
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );

  Future<void> cleanLogFiles() async {
    final files = ['app.log', 'app.log.1', 'app.log.2', 'app.log.3'];
    for (final f in files) {
      final file = File(f);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  setUp(() async {
    await AppLogService.instance.pendingWrites;
    AppLogService.instance.resetLogFileForTesting();
    await cleanLogFiles();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return '.'; // Use current directory as support directory for testing
        });
  });

  tearDown(() async {
    await AppLogService.instance.pendingWrites;
    AppLogService.instance.clear();
    AppLogService.instance.resetLogFileForTesting();
    await cleanLogFiles();
  });

  test('redacts credentials from message and details', () {
    final logs = AppLogService.instance;
    logs.clear();

    logs.error(
      'request failed password=super-secret Bearer abc.def.ghi',
      details: 'private_key=my-key token=my-token',
      error: 'boom',
    );

    final entry = logs.entries.first;
    expect(entry.message, isNot(contains('super-secret')));
    expect(entry.message, isNot(contains('abc.def.ghi')));
    expect(entry.details, isNot(contains('my-key')));
    expect(entry.details, isNot(contains('my-token')));
    expect(entry.message, contains('[REDACTED]'));
  });

  test(
    'redacts stack traces, URL tokens, cookies, and private key blocks',
    () async {
      final logs = AppLogService.instance;
      logs.clear();

      logs.add(
        'error',
        'GET https://example.com?access_token=abc123',
        details: 'Cookie: sid=secret-cookie',
        stackTrace: StackTrace.fromString(
          'Authorization: Basic dXNlcjpwYXNz\n'
          '-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n'
          '-----END OPENSSH PRIVATE KEY-----',
        ),
      );

      final entry = logs.entries.first;
      expect(entry.message, isNot(contains('abc123')));
      expect(entry.details, isNot(contains('secret-cookie')));
      expect(entry.stackTrace, isNot(contains('dXNlcjpwYXNz')));
      expect(entry.stackTrace, isNot(contains('secret')));
      expect(entry.text, contains('[REDACTED]'));

      await logs.pendingWrites;
      final logFile = File('app.log');
      final content = await logFile.readAsString();
      expect(content, isNot(contains('abc123')));
      expect(content, isNot(contains('secret-cookie')));
      expect(content, isNot(contains('dXNlcjpwYXNz')));
    },
  );

  test('level counts update when entries are deleted', () {
    final logs = AppLogService.instance;
    logs.clear();
    logs.info('one');
    logs.warning('two');
    final warningId = logs.entries.first.id;

    expect(logs.levelCounts[AppLogLevel.all], 2);

    logs.deleteEntriesById({warningId});

    expect(logs.levelCounts[AppLogLevel.all], 1);
    expect(logs.entries.single.message, 'one');
  });

  test(
    'AppLogService adapts Core Logger scopes without changing old entries',
    () {
      final logs = AppLogService.instance;
      logs.clear();
      final terminalLogger = logs.scope('terminal');

      terminalLogger.log(
        app_core.LogRecord(
          timestamp: DateTime.utc(2026, 8, 7),
          level: app_core.LogLevel.info,
          message: 'scoped message',
        ),
      );

      expect(logs.entries.single.message, 'scoped message');
      expect(logs.entries.single.sourceLocation, 'terminal');
      expect(logs.entries.single.normalizedLevel, AppLogLevel.info);
    },
  );

  test('forwards Core records to an attached sink exactly once', () {
    final logs = AppLogService.instance;
    logs.clear();
    final sink = _RecordingLogSink();
    final record = app_core.LogRecord(
      timestamp: DateTime.utc(2026, 8, 7),
      level: app_core.LogLevel.warning,
      message: 'structured warning',
    );

    logs.addSink(sink);
    logs.addSink(sink);
    logs.log(record);

    expect(sink.records, hasLength(1));
    expect(sink.records.single, same(record));

    logs.removeSink(sink);
    logs.log(
      app_core.LogRecord(
        timestamp: DateTime.utc(2026, 8, 7, 0, 1),
        level: app_core.LogLevel.info,
        message: 'after removal',
      ),
    );
    expect(sink.records, hasLength(1));
  });

  test('a failing sink cannot prevent local log forwarding', () {
    final logs = AppLogService.instance;
    logs.clear();
    final sink = _ThrowingLogSink();
    logs.addSink(sink);

    expect(
      () => logs.log(
        app_core.LogRecord(
          timestamp: DateTime.utc(2026, 8, 7),
          level: app_core.LogLevel.error,
          message: 'local error',
        ),
      ),
      returnsNormally,
    );
    expect(logs.entries.single.message, 'local error');

    logs.removeSink(sink);
  });

  test('rotates log files when limit is exceeded', () async {
    final logs = AppLogService.instance;
    logs.clear();

    // Set a tiny limit for testing log rotation
    logs.logSizeLimit = 50; // 50 bytes

    // Adding logs should write to disk.
    logs.info('Log entry one');
    await logs.pendingWrites;

    // Check that app.log exists and contains the text
    final logFile = File('app.log');
    expect(await logFile.exists(), true);
    var content = await logFile.readAsString();
    expect(content, contains('Log entry one'));

    // Write more logs to trigger rotation
    logs.info('Log entry two');
    await logs.pendingWrites;

    logs.info('Log entry three');
    await logs.pendingWrites;

    logs.info('Log entry four');
    await logs.pendingWrites;

    // After multiple writes exceeding 50 bytes, rotation should have occurred.
    // Check that rotated files exist
    final logFile1 = File('app.log.1');
    expect(await logFile1.exists(), true);

    // Reset size limit back to default 5MB
    logs.logSizeLimit = 5 * 1024 * 1024;
  });
}
