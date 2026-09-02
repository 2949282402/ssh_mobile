import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'ssh_mobile_sftp_cache_edge_',
    );
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
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
      } catch (_) {}
    }
  });

  test('directory cache invalidates paths, targets, and unknown entries', () {
    final cache = SftpDirectoryCache();
    final entries = <SftpEntry>[_entry('first.txt')];
    cache.set('connection', 'target', '/one', entries);
    expect(cache.get('connection', 'target', '/one'), same(entries));
    expect(cache.get('connection', 'target', '/missing'), isNull);

    cache.invalidate('connection', 'target', '/one');
    expect(cache.get('connection', 'target', '/one'), isNull);
    cache.invalidate('connection', 'target', '/missing');
    cache.set('connection', 'target', '/two', entries);
    cache.invalidate('connection', 'target');
    expect(cache.get('connection', 'target', '/two'), isNull);
    cache.invalidate('unknown', 'target');
    cache.clear();
  });

  test(
    'rejects negative bounds and keeps sensitive paths out of disk cache',
    () async {
      await expectLater(
        SftpFileCache.get(
          'connection',
          'target',
          '/tmp/a',
          1,
          null,
          maxBytes: -1,
        ),
        throwsArgumentError,
      );
      await SftpFileCache.put(
        'connection',
        'target',
        '/home/test/.ssh/id_ed25519',
        1,
        null,
        Uint8List.fromList([1]),
      );
      expect(await _cacheFiles(tempDir), isEmpty);
    },
  );

  test('removes stale metadata and legacy cache names', () async {
    final bytes = Uint8List.fromList(utf8.encode('stale-data'));
    await SftpFileCache.put(
      'connection',
      'target',
      '/tmp/stale',
      10,
      null,
      bytes,
    );
    await SftpFileCache.put(
      'connection',
      'target',
      '/tmp/stale',
      11,
      null,
      bytes,
    );
    expect(await _cacheFiles(tempDir), hasLength(1));
    expect(
      await SftpFileCache.get('connection', 'target', '/tmp/stale', 10, null),
      isNull,
    );
    expect(await _cacheFiles(tempDir), isEmpty);

    final legacyName =
        'sftp_cache_${_hash('connection:/tmp/legacy')}_legacy-entry';
    final legacyFile = File('${tempDir.path}/$legacyName')
      ..writeAsStringSync('legacy');
    expect(
      await SftpFileCache.get('connection', 'target', '/tmp/legacy', 1, null),
      isNull,
    );
    expect(await legacyFile.exists(), isFalse);
  });

  test('enforces bounded encrypted and plaintext cache reads', () async {
    final bytes = Uint8List.fromList(List<int>.generate(700, (index) => index));
    await SftpFileCache.put(
      'connection',
      'target',
      '/tmp/bounded',
      bytes.length,
      null,
      bytes,
    );
    final file = (await _cacheFiles(tempDir)).single;
    final encryptedLength = await file.length();
    expect(
      await SftpFileCache.get(
        'connection',
        'target',
        '/tmp/bounded',
        bytes.length,
        null,
        maxBytes: 0,
      ),
      isNull,
    );
    expect(await file.exists(), isFalse);

    await SftpFileCache.put(
      'connection',
      'target',
      '/tmp/bounded',
      bytes.length,
      null,
      bytes,
    );
    final restoredFile = (await _cacheFiles(tempDir)).single;
    final envelopeMinimum = ((encryptedLength - 512) / 2).ceil();
    final plaintextLimit = envelopeMinimum < bytes.length
        ? envelopeMinimum
        : bytes.length - 1;
    expect(plaintextLimit, lessThan(bytes.length));
    expect(
      await SftpFileCache.get(
        'connection',
        'target',
        '/tmp/bounded',
        bytes.length,
        null,
        maxBytes: plaintextLimit,
      ),
      isNull,
    );
    expect(await restoredFile.exists(), isFalse);
  });

  test('clears connection-scoped and unscoped legacy files', () async {
    final connectionHash = _hash('connection');
    final scoped = File('${tempDir.path}/sftp_cache_${connectionHash}_scoped')
      ..writeAsStringSync('scoped');
    final legacy = File('${tempDir.path}/sftp_cache_a_b_c')
      ..writeAsStringSync('legacy');
    final ignored = File('${tempDir.path}/unrelated')
      ..writeAsStringSync('keep');
    await Directory(
      '${tempDir.path}/sftp_cache_${connectionHash}_directory',
    ).create();

    await SftpFileCache.clearConnection('connection');
    expect(await scoped.exists(), isFalse);
    expect(await legacy.exists(), isFalse);
    expect(await ignored.exists(), isTrue);
  });
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

Future<List<File>> _cacheFiles(Directory directory) => directory
    .list()
    .where((entity) => entity is File)
    .cast<File>()
    .where((file) => file.uri.pathSegments.last.startsWith('sftp_cache_'))
    .toList();

SftpEntry _entry(String name) => SftpEntry(
  connectionId: 'connection',
  targetFingerprint: 'target',
  name: name,
  path: '/$name',
  lowerName: name.toLowerCase(),
  isDirectory: false,
  isLink: false,
  size: 1,
  sizeLabel: '1 B',
);
