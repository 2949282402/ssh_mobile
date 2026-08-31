import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:connection_core/connection_core.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;
  late String serverOneTarget;
  late String serverTwoTarget;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ssh_mobile_sftp_cache_');
    serverOneTarget = _targetFingerprint('server-1', 'one.example.com');
    serverTwoTarget = _targetFingerprint('server-2', 'two.example.com');
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
      serverOneTarget,
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
      serverOneTarget,
      '/tmp/demo.txt',
      bytes.length,
      modifiedAt,
    );
    expect(cached, bytes);
  });

  test('does not write cache for sensitive paths', () async {
    await SftpFileCache.put(
      'server-1',
      serverOneTarget,
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
      serverOneTarget,
      '/tmp/demo.txt',
      bytes.length,
      modifiedAt,
      bytes,
    );
    final file = (await _cacheFiles(tempDir)).single;
    await file.writeAsString('ssh-mobile-bin-v1:not-valid-base64');

    final cached = await SftpFileCache.get(
      'server-1',
      serverOneTarget,
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
      serverOneTarget,
      '/tmp/one.txt',
      1,
      modifiedAt,
      Uint8List.fromList([1]),
    );
    await SftpFileCache.put(
      'server-2',
      serverTwoTarget,
      '/tmp/two.txt',
      1,
      modifiedAt,
      Uint8List.fromList([2]),
    );

    await SftpFileCache.clearConnection('server-1');

    expect(
      await SftpFileCache.get(
        'server-1',
        serverOneTarget,
        '/tmp/one.txt',
        1,
        modifiedAt,
      ),
      isNull,
    );
    expect(
      await SftpFileCache.get(
        'server-2',
        serverTwoTarget,
        '/tmp/two.txt',
        1,
        modifiedAt,
      ),
      Uint8List.fromList([2]),
    );
  });

  test(
    'same connection id rebind isolates encrypted preview cache by target',
    () async {
      final oldTarget = _targetFingerprint('server-1', 'old.example.com');
      final newTarget = _targetFingerprint('server-1', 'new.example.com');
      final modifiedAt = DateTime.utc(2026, 7, 13);
      final oldBytes = Uint8List.fromList('old-host'.codeUnits);
      final newBytes = Uint8List.fromList('new-host'.codeUnits);

      await SftpFileCache.put(
        'server-1',
        oldTarget,
        '/srv/status.txt',
        oldBytes.length,
        modifiedAt,
        oldBytes,
      );

      expect(
        await SftpFileCache.get(
          'server-1',
          newTarget,
          '/srv/status.txt',
          oldBytes.length,
          modifiedAt,
        ),
        isNull,
      );

      await SftpFileCache.put(
        'server-1',
        newTarget,
        '/srv/status.txt',
        newBytes.length,
        modifiedAt,
        newBytes,
      );

      expect(
        await SftpFileCache.get(
          'server-1',
          oldTarget,
          '/srv/status.txt',
          oldBytes.length,
          modifiedAt,
        ),
        oldBytes,
      );
      expect(
        await SftpFileCache.get(
          'server-1',
          newTarget,
          '/srv/status.txt',
          newBytes.length,
          modifiedAt,
        ),
        newBytes,
      );

      final files = await _cacheFiles(tempDir);
      expect(files, hasLength(2));
      for (final file in files) {
        final name = p.basename(file.path);
        expect(name, isNot(contains('old.example.com')));
        expect(name, isNot(contains('new.example.com')));
        expect(name, isNot(contains(oldTarget)));
        expect(name, isNot(contains(newTarget)));
      }
    },
  );

  test('same connection id rebind isolates directory cache by target', () {
    final oldTarget = _targetFingerprint('server-1', 'old.example.com');
    final newTarget = _targetFingerprint('server-1', 'new.example.com');
    final oldEntries = [_entry('server-1', 'old-host.txt')];
    final newEntries = [_entry('server-1', 'new-host.txt')];
    final cache = SftpDirectoryCache();

    cache.set('server-1', oldTarget, '/srv', oldEntries);

    expect(cache.get('server-1', newTarget, '/srv'), isNull);

    cache.set('server-1', newTarget, '/srv', newEntries);
    expect(cache.get('server-1', oldTarget, '/srv'), same(oldEntries));
    expect(cache.get('server-1', newTarget, '/srv'), same(newEntries));

    cache.invalidate('server-1', newTarget);
    expect(cache.get('server-1', newTarget, '/srv'), isNull);
    expect(cache.get('server-1', oldTarget, '/srv'), same(oldEntries));
  });
}

String _targetFingerprint(String id, String host) {
  return ConnectionTargetBinding.fromConfig(_connection(id, host)).fingerprint;
}

ConnectionConfig _connection(String id, String host) =>
    ConnectionConfig(id: id, name: id, host: host, username: 'tester');

SftpEntry _entry(String connectionId, String name) {
  return SftpEntry(
    connectionId: connectionId,
    targetFingerprint: 'test-target',
    name: name,
    path: '/srv/$name',
    lowerName: name.toLowerCase(),
    isDirectory: false,
    isLink: false,
    sizeLabel: '1 B',
    size: 1,
  );
}

Future<List<File>> _cacheFiles(Directory directory) {
  return directory
      .list()
      .where((entity) => entity is File)
      .cast<File>()
      .where((file) => p.basename(file.path).startsWith('sftp_cache_'))
      .toList();
}
