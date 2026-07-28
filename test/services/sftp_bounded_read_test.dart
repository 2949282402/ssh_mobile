import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/sftp/sftp_service_io.dart';
import 'package:ssh_mobile/services/sftp_service.dart' hide SftpService;
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'ssh_mobile_sftp_bounded_read_',
    );
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => tempDir.path,
        );
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

  test(
    'bounded read returns normal files in chunks and closes the handle',
    () async {
      final bytes = Uint8List.fromList(
        List<int>.generate((70 * 1024) + 7, (index) => index % 251),
      );
      final fixture = _ServiceFixture(bytes: bytes, declaredSize: bytes.length);
      addTearDown(fixture.dispose);

      final result = await fixture.service.downloadBytes(
        fixture.entry,
        maxBytes: 80 * 1024,
        bypassCache: true,
      );

      expect(result, bytes);
      expect(fixture.remote.readOffsets, [0, 64 * 1024]);
      expect(fixture.remote.requestedLengths, [64 * 1024, (16 * 1024) + 1]);
      expect(fixture.remote.closedReadPaths, [fixture.entry.path]);
    },
  );

  test(
    'misreported size stops at max plus one and closes the handle',
    () async {
      const maxBytes = 70 * 1024;
      final fixture = _ServiceFixture(
        bytes: Uint8List(maxBytes + (64 * 1024)),
        declaredSize: 1,
      );
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.service.downloadBytes(
          fixture.entry,
          maxBytes: maxBytes,
          bypassCache: true,
        ),
        throwsA(
          isA<SftpFileSizeLimitException>()
              .having(
                (error) => error.observedBytes,
                'observedBytes',
                maxBytes + 1,
              )
              .having((error) => error.maxBytes, 'maxBytes', maxBytes),
        ),
      );

      expect(fixture.remote.requestedLengths, [64 * 1024, (6 * 1024) + 1]);
      expect(fixture.remote.totalBytesReturned, maxBytes + 1);
      expect(fixture.remote.closedReadPaths, [fixture.entry.path]);
    },
  );

  test(
    'known oversized metadata is rejected before opening the file',
    () async {
      final fixture = _ServiceFixture(bytes: Uint8List(128), declaredSize: 128);
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.service.downloadBytes(fixture.entry, maxBytes: 64),
        throwsA(
          isA<SftpFileSizeLimitException>().having(
            (error) => error.observedBytes,
            'observedBytes',
            128,
          ),
        ),
      );

      expect(fixture.remote.openCount, 0);
      expect(fixture.remote.totalBytesReturned, 0);
    },
  );

  test(
    'bypassCache fetches remote bytes and replaces the cached value',
    () async {
      final fixture = _ServiceFixture(
        bytes: Uint8List.fromList('old'.codeUnits),
        declaredSize: 3,
      );
      addTearDown(fixture.dispose);

      expect(
        await fixture.service.downloadBytes(fixture.entry),
        'old'.codeUnits,
      );
      expect(fixture.remote.openCount, 1);

      fixture.remote.setFile(Uint8List.fromList('new'.codeUnits));
      expect(
        await fixture.service.downloadBytes(fixture.entry),
        'old'.codeUnits,
      );
      expect(fixture.remote.openCount, 1);

      expect(
        await fixture.service.downloadBytes(fixture.entry, bypassCache: true),
        'new'.codeUnits,
      );
      expect(fixture.remote.openCount, 2);

      expect(
        await fixture.service.downloadBytes(fixture.entry),
        'new'.codeUnits,
      );
      expect(fixture.remote.openCount, 2);
    },
  );

  test(
    'oversized encrypted cache is invalidated before bounded remote read',
    () async {
      final fixture = _ServiceFixture(bytes: Uint8List(1), declaredSize: 1);
      addTearDown(fixture.dispose);
      final cachedBytes = Uint8List.fromList(List<int>.filled(64, 7));

      await SftpFileCache.put(
        fixture.connection.id,
        fixture.targetFingerprint,
        fixture.entry.path,
        fixture.entry.size,
        fixture.entry.modifiedAt,
        cachedBytes,
      );

      expect(
        await fixture.service.downloadBytes(fixture.entry, maxBytes: 8),
        Uint8List(1),
      );

      expect(fixture.remote.openCount, 1);
      expect(fixture.remote.totalBytesReturned, 1);
      expect(
        await fixture.service.downloadBytes(fixture.entry, maxBytes: 8),
        Uint8List(1),
      );
      expect(fixture.remote.openCount, 1);
    },
  );
}

class _ServiceFixture {
  _ServiceFixture({required Uint8List bytes, required int declaredSize})
    : connection = ConnectionConfig(
        id: 'server-1',
        name: 'server-1',
        host: 'one.example.com',
        username: 'tester',
      ),
      remote = _BoundedReadSftpClient('/srv/demo.bin', bytes),
      storage = _NoopStorageService() {
    targetFingerprint = ConnectionTargetBinding.fromConfig(
      connection,
    ).fingerprint;
    service = SftpService.forTesting(
      storage,
      connection: connection,
      sftpClient: remote,
      currentPath: '/srv',
    );
    entry = SftpEntry(
      connectionId: connection.id,
      name: 'demo.bin',
      path: '/srv/demo.bin',
      lowerName: 'demo.bin',
      isDirectory: false,
      isLink: false,
      size: declaredSize,
      sizeLabel: '$declaredSize B',
      modifiedAt: DateTime.utc(2026, 7, 14),
    );
  }

  final ConnectionConfig connection;
  final _BoundedReadSftpClient remote;
  final _NoopStorageService storage;
  late final String targetFingerprint;
  late final SftpService service;
  late final SftpEntry entry;

  void dispose() {
    service.dispose();
    storage.dispose();
  }
}

class _NoopStorageService extends StorageService {
  @override
  Future<void> recordVisitedPath(String connectionId, String path) async {}
}

class _BoundedReadSftpClient implements SftpClient {
  _BoundedReadSftpClient(this.path, Uint8List bytes) : _bytes = bytes;

  final String path;
  Uint8List _bytes;
  int openCount = 0;
  int totalBytesReturned = 0;
  final List<int> readOffsets = [];
  final List<int> requestedLengths = [];
  final List<String> closedReadPaths = [];

  void setFile(Uint8List bytes) {
    _bytes = bytes;
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    openCount += 1;
    return _BoundedReadSftpFile(this, path);
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP client call: $invocation');
}

class _BoundedReadSftpFile implements SftpFile {
  _BoundedReadSftpFile(this.client, this.path);

  final _BoundedReadSftpClient client;
  final String path;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    if (_isClosed) throw StateError('File is closed');
    final requested = length ?? client._bytes.length - offset;
    client.readOffsets.add(offset);
    client.requestedLengths.add(requested);
    if (offset >= client._bytes.length) return Uint8List(0);
    final end = (offset + requested) < client._bytes.length
        ? offset + requested
        : client._bytes.length;
    final result = Uint8List.sublistView(client._bytes, offset, end);
    client.totalBytesReturned += result.length;
    return Uint8List.fromList(result);
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    client.closedReadPaths.add(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP file call: $invocation');
}
