import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connection_core/connection_core.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';
import '../test_utils/test_storage_adapter.dart';

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

  test('text save invalidates file and target directory caches', () async {
    final connection = _connection('server-1', 'one.example.com');
    final targetFingerprint = ConnectionTargetBinding.fromConfig(
      connection,
    ).fingerprint;
    final remote = _FakeDartSftpClient()
      ..setFile('/srv/note.txt', utf8.encode('old'))
      ..setListing('/srv', [_remoteFile('note.txt', size: 3)])
      ..setListing('/other', [_remoteFile('other.txt', size: 4)]);
    final storage = _NoopStorageService();
    final service = SftpService.forTesting(
      storage.connectionRepository,
      storage.credentialRepository,
      storage.hostKeyRepository,
      connection: connection,
      sftpClient: remote,
      currentPath: '/srv',
    );
    addTearDown(() {
      service.dispose();
      storage.dispose();
    });

    await service.openPath('/srv');
    final entry = service.entries.single;
    await service.openPath('/other');
    await SftpFileCache.put(
      connection.id,
      targetFingerprint,
      entry.path,
      entry.size,
      entry.modifiedAt,
      Uint8List.fromList(utf8.encode('old')),
    );
    remote.setListing('/srv', [_remoteFile('fresh.txt', size: 5)]);
    remote.events.clear();

    await service.saveTextFile(entry, 'new');

    expect(remote.events.take(3), [
      'write:${entry.path}',
      'close:${entry.path}',
      'list:/other',
    ]);
    expect(remote.fileBytes(entry.path), utf8.encode('new'));
    expect(remote.closedWritePaths, contains(entry.path));
    expect(
      await SftpFileCache.get(
        connection.id,
        targetFingerprint,
        entry.path,
        entry.size,
        entry.modifiedAt,
      ),
      isNull,
    );
    expect(await service.downloadBytes(entry), utf8.encode('new'));
    expect(remote.readCount(entry.path), 1);

    await service.openPath('/srv');

    expect(remote.listCount('/srv'), 2);
    expect(service.entries.single.name, 'fresh.txt');
  });

  test('manual refresh bypasses a valid directory cache entry', () async {
    final connection = _connection('server-1', 'one.example.com');
    final remote = _FakeDartSftpClient()
      ..setListing('/srv', [_remoteFile('old.txt', size: 3)]);
    final storage = _NoopStorageService();
    final service = SftpService.forTesting(
      storage.connectionRepository,
      storage.credentialRepository,
      storage.hostKeyRepository,
      connection: connection,
      sftpClient: remote,
      currentPath: '/srv',
    );
    addTearDown(() {
      service.dispose();
      storage.dispose();
    });

    await service.openPath('/srv');
    expect(remote.listCount('/srv'), 1);
    expect(service.entries.single.name, 'old.txt');
    remote.setListing('/srv', [_remoteFile('fresh.txt', size: 5)]);

    await service.openPath('/srv');

    expect(remote.listCount('/srv'), 1);
    expect(service.entries.single.name, 'old.txt');

    await service.refresh();

    expect(remote.listCount('/srv'), 2);
    expect(service.currentPath, '/srv');
    expect(service.state, SftpConnectionState.connected);
    expect(service.entries.single.name, 'fresh.txt');
  });
}

ConnectionConfig _connection(String id, String host) =>
    ConnectionConfig(id: id, name: id, host: host, username: 'tester');

SftpName _remoteFile(String filename, {required int size}) {
  return SftpName(
    filename: filename,
    longname: filename,
    attr: SftpFileAttrs(size: size, modifyTime: 1700000000),
  );
}

class _NoopStorageService extends TestStorageAdapter {
  @override
  Future<void> recordVisitedPath(String connectionId, String path) async {}
}

class _FakeDartSftpClient implements SftpClient {
  final Map<String, Uint8List> _files = {};
  final Map<String, List<SftpName>> _listings = {};
  final Map<String, int> _listCounts = {};
  final Map<String, int> _readCounts = {};
  final Set<String> closedWritePaths = {};
  final List<String> events = [];

  void setFile(String path, List<int> bytes) {
    _files[path] = Uint8List.fromList(bytes);
  }

  Uint8List? fileBytes(String path) {
    final bytes = _files[path];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  void setListing(String path, List<SftpName> entries) {
    _listings[path] = List<SftpName>.from(entries);
  }

  int listCount(String path) => _listCounts[path] ?? 0;

  int readCount(String path) => _readCounts[path] ?? 0;

  @override
  Future<String> absolute(String path) async => path;

  @override
  Future<List<SftpName>> listdir(String path) async {
    _listCounts[path] = listCount(path) + 1;
    events.add('list:$path');
    return List<SftpName>.from(_listings[path] ?? const []);
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    final isWritable = (mode.flag & SftpFileOpenMode.write.flag) != 0;
    if ((mode.flag & SftpFileOpenMode.truncate.flag) != 0) {
      _files[path] = Uint8List(0);
    }
    return _FakeDartSftpFile(this, path, isWritable: isWritable);
  }

  @override
  Future<void> close() async {}

  Uint8List _read(String path) {
    _readCounts[path] = readCount(path) + 1;
    return Uint8List.fromList(_files[path] ?? const []);
  }

  void _write(String path, Uint8List data, int offset) {
    events.add('write:$path');
    final current = _files[path] ?? Uint8List(0);
    final requiredLength = offset + data.length;
    final result = Uint8List(
      requiredLength > current.length ? requiredLength : current.length,
    )..setRange(0, current.length, current);
    result.setRange(offset, requiredLength, data);
    _files[path] = result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP client call: $invocation');
}

class _FakeDartSftpFile implements SftpFile {
  _FakeDartSftpFile(this._client, this._path, {required this.isWritable});

  final _FakeDartSftpClient _client;
  final String _path;
  final bool isWritable;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    final bytes = _client._read(_path);
    final available = bytes.sublist(offset);
    return Uint8List.fromList(
      length == null ? available : available.take(length).toList(),
    );
  }

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    if (!isWritable) throw StateError('File is not writable');
    _client._write(_path, data, offset);
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    if (isWritable) {
      _client.events.add('close:$_path');
      _client.closedWritePaths.add(_path);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP file call: $invocation');
}
