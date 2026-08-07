import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_terminal/feature_terminal.dart';

void main() {
  late Directory temporaryDirectory;
  late TerminalHistoryService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'feature_terminal_history_test_',
    );
    service = TerminalHistoryService(
      dataProtection: _FakeOutputProtector(),
      logger: _FakeTerminalLogger(),
      historyDirectoryProvider: () async => temporaryDirectory,
    );
  });

  tearDown(() async {
    await service.dispose();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('serializes encrypted output and reads the decrypted tail', () async {
    await Future.wait(<Future<void>>[
      service.append('session/one', 'hello'),
      service.append('session/one', ' world'),
    ]);
    await service.flush();

    final file = await service.historyFile('session/one') as File;
    final stored = await file.readAsString();
    expect(stored, contains('enc:'));
    expect(stored, isNot(contains('hello')));
    expect(await service.readTail('session/one'), 'hello world');
  });

  test(
    'migrates existing plaintext before appending encrypted output',
    () async {
      final file = await service.historyFile('legacy') as File;
      await file.writeAsString('legacy output');

      await service.append('legacy', ' + new');
      await service.flush();

      expect(await service.readTail('legacy'), 'legacy output + new');
      expect((await file.readAsLines()).first, startsWith('enc:'));
    },
  );
}

final class _FakeOutputProtector implements TerminalHistoryOutputProtector {
  @override
  String get encryptedPrefix => 'enc:';

  @override
  bool isEncrypted(String value) => value.startsWith(encryptedPrefix);

  @override
  Future<String> encryptString(String value) async {
    return '$encryptedPrefix${base64Url.encode(utf8.encode(value))}';
  }

  @override
  Future<String> decryptString(String value) async {
    return utf8.decode(
      base64Url.decode(value.substring(encryptedPrefix.length)),
    );
  }
}

final class _FakeTerminalLogger implements TerminalLoggerPort {
  @override
  void info(String message) {}

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) {}

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) {}
}
