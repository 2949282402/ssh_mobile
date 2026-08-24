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

  test(
    'streams large plaintext migration in bounded encrypted chunks',
    () async {
      final protector = _TrackingOutputProtector();
      final streamingService = TerminalHistoryService(
        dataProtection: protector,
        logger: _FakeTerminalLogger(),
        historyDirectoryProvider: () async => temporaryDirectory,
      );
      addTearDown(streamingService.dispose);
      final file = await streamingService.historyFile('large-legacy') as File;
      final legacy = '${_repeat('a', 90000)}\u{1F680}${_repeat('b', 90000)}';
      await file.writeAsString(legacy);

      await streamingService.append('large-legacy', ' tail');
      await streamingService.flush();

      expect(protector.largestEncryptedPlaintext, lessThanOrEqualTo(32 * 1024));
      expect(protector.encryptCalls, greaterThan(2));
      expect(await streamingService.readTail('large-legacy'), '$legacy tail');
    },
  );

  test(
    'failed migration leaves original plaintext atomically intact',
    () async {
      final failingService = TerminalHistoryService(
        dataProtection: _FailingOutputProtector(),
        logger: _FakeTerminalLogger(),
        historyDirectoryProvider: () async => temporaryDirectory,
      );
      addTearDown(failingService.dispose);
      final file = await failingService.historyFile('failed-legacy') as File;
      const legacy = 'legacy plaintext must survive failed migration';
      await file.writeAsString(legacy);

      await expectLater(
        failingService.append('failed-legacy', ' new'),
        throwsA(isA<StateError>()),
      );

      expect(await file.readAsString(), legacy);
      expect(temporaryDirectory.listSync().whereType<Directory>(), isEmpty);
    },
  );
}

class _FakeOutputProtector implements TerminalHistoryOutputProtector {
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

final class _TrackingOutputProtector extends _FakeOutputProtector {
  int encryptCalls = 0;
  int largestEncryptedPlaintext = 0;

  @override
  Future<String> encryptString(String value) {
    encryptCalls++;
    if (value.length > largestEncryptedPlaintext) {
      largestEncryptedPlaintext = value.length;
    }
    return super.encryptString(value);
  }
}

final class _FailingOutputProtector extends _FakeOutputProtector {
  @override
  Future<String> encryptString(String value) async {
    throw StateError('injected encryption failure');
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

String _repeat(String value, int count) =>
    List<String>.filled(count, value, growable: false).join();
