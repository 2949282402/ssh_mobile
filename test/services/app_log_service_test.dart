import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('plugins.flutter.io/path_provider');

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
    await cleanLogFiles();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return '.'; // Use current directory as support directory for testing
    });
  });

  tearDown(() async {
    AppLogService.instance.clear();
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

  test('redacts stack traces, URL tokens, cookies, and private key blocks',
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

    await Future.delayed(const Duration(milliseconds: 100));
    final logFile = File('app.log');
    final content = await logFile.readAsString();
    expect(content, isNot(contains('abc123')));
    expect(content, isNot(contains('secret-cookie')));
    expect(content, isNot(contains('dXNlcjpwYXNz')));
  });

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

  test('rotates log files when limit is exceeded', () async {
    final logs = AppLogService.instance;
    logs.clear();

    // Set a tiny limit for testing log rotation
    logs.logSizeLimit = 50; // 50 bytes

    // Adding logs should write to disk. Since it's async, let's wait a bit.
    logs.info('Log entry one');
    await Future.delayed(const Duration(milliseconds: 100));

    // Check that app.log exists and contains the text
    final logFile = File('app.log');
    expect(await logFile.exists(), true);
    var content = await logFile.readAsString();
    expect(content, contains('Log entry one'));

    // Write more logs to trigger rotation
    logs.info('Log entry two');
    await Future.delayed(const Duration(milliseconds: 100));

    logs.info('Log entry three');
    await Future.delayed(const Duration(milliseconds: 100));

    logs.info('Log entry four');
    await Future.delayed(const Duration(milliseconds: 100));

    // After multiple writes exceeding 50 bytes, rotation should have occurred.
    // Check that rotated files exist
    final logFile1 = File('app.log.1');
    expect(await logFile1.exists(), true);

    // Reset size limit back to default 5MB
    logs.logSizeLimit = 5 * 1024 * 1024;
  });
}
