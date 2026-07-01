import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ssh_mobile/services/sftp/sftp_service_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ssh_mobile_sftp_cache_');
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (_) async {
      return tempDir.path;
    });
    await SftpFileCache.clearAll();
  });

  tearDown(() async {
    await SftpFileCache.clearAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // Windows can briefly keep app.log open after async log writes.
      }
    }
  });

  test('encrypts cache files and restores plaintext on read', () async {
    final modifiedAt = DateTime.utc(2026, 6, 18);
    final bytes = Uint8List.fromList('hello-cache'.codeUnits);

    await SftpFileCache.put(
      'server-1',
      '/tmp/demo.txt',
      bytes.length,
      modifiedAt,
      bytes,
    );

    final files = await _cacheFiles(tempDir);
    expect(files, hasLength(1));

    final diskBytes = await files.single.readAsBytes();
    expect(diskBytes, isNot(equals(bytes)));
    expect(String.fromCharCodes(diskBytes), startsWith('ssh-mobile-bin-v1:'));

    final cached = await SftpFileCache.get(
      'server-1',
      '/tmp/demo.txt',
      bytes.length,
      modifiedAt,
    );
    expect(cached, bytes);
  });

  test('does not write cache for sensitive paths', () async {
    await SftpFileCache.put(
      'server-1',
      '/home/demo/.ssh/id_rsa',
      4,
      DateTime.utc(2026, 6, 18),
      Uint8List.fromList([1, 2, 3, 4]),
    );

    final files = await _cacheFiles(tempDir);
    expect(files, isEmpty);
  });

  test('invalid encrypted cache is deleted and treated as miss', () async {
    final modifiedAt = DateTime.utc(2026, 6, 18);
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await SftpFileCache.put(
      'server-1',
      '/tmp/demo.txt',
      bytes.length,
      modifiedAt,
      bytes,
    );
    final file = (await _cacheFiles(tempDir)).single;
    await file.writeAsString('ssh-mobile-bin-v1:not-valid-base64');

    final cached = await SftpFileCache.get(
      'server-1',
      '/tmp/demo.txt',
      bytes.length,
      modifiedAt,
    );

    expect(cached, isNull);
    expect(await file.exists(), isFalse);
  });

  test('clearConnection removes only the selected connection cache', () async {
    final modifiedAt = DateTime.utc(2026, 6, 18);
    await SftpFileCache.put(
      'server-1',
      '/tmp/one.txt',
      1,
      modifiedAt,
      Uint8List.fromList([1]),
    );
    await SftpFileCache.put(
      'server-2',
      '/tmp/two.txt',
      1,
      modifiedAt,
      Uint8List.fromList([2]),
    );

    await SftpFileCache.clearConnection('server-1');

    expect(
      await SftpFileCache.get('server-1', '/tmp/one.txt', 1, modifiedAt),
      isNull,
    );
    expect(
      await SftpFileCache.get('server-2', '/tmp/two.txt', 1, modifiedAt),
      Uint8List.fromList([2]),
    );
  });
}

Future<List<File>> _cacheFiles(Directory directory) {
  return directory
      .list()
      .where((entity) => entity is File)
      .cast<File>()
      .where((file) => p.basename(file.path).startsWith('sftp_cache_'))
      .toList();
}
