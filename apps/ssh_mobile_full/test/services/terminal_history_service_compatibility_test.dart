import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/terminal_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'ssh_mobile_terminal_history_',
    );
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (_) async {
          return supportDirectory.path;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test('compatibility facade exposes protected history operations', () async {
    final service = TerminalHistoryService();
    await service.append('session/one', 'hello');
    await service.flush();
    expect(await service.readTail('session/one'), 'hello');
    final historyFile = await service.historyFile('session/one');
    expect(historyFile, isA<File>());
    await service.dispose();
    await service.dispose();
    await service.append('session/one', 'ignored');
    expect(await service.readTail('session/one'), 'hello');
  });

  test(
    'facade logger paths report malformed history and write failures',
    () async {
      final service = TerminalHistoryService();
      final malformed = await service.historyFile('malformed') as File;
      await malformed.parent.create(recursive: true);
      await malformed.writeAsString('ssh-mobile-v1:not-base64\n');
      expect(await service.readTail('malformed'), isEmpty);

      final plain = await service.historyFile('plain') as File;
      await plain.writeAsString('legacy output');
      await service.append('plain', ' plus encrypted');
      await service.flush();
      expect(await service.readTail('plain'), 'legacy output plus encrypted');

      final failedPath = await service.historyFile('failed') as File;
      await Directory(failedPath.path).create(recursive: true);
      await expectLater(
        service.append('failed', 'will fail'),
        throwsA(isA<Object>()),
      );
      await service.dispose();
      await Directory(failedPath.path).delete(recursive: true);
    },
  );
}
