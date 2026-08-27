// SFTP 传输生命周期遥测生产者测试。
//
// 覆盖 downloadBytes / uploadBytesPathForConnection 的
// started -> completed / started -> failed 生命周期：
// - started 与 completed/failed 共享同一 traceId；
// - completed 带 bytes_transferred + duration_ms；
// - failed 带注册错误码与 stage（download/upload）。
// 使用 SftpService.forTesting + 内存 SftpClient 假实现，避免真实网络。

import 'dart:async';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';

import '../../test_utils/test_storage_adapter.dart';
import 'telemetry_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SFTP transfer telemetry producers', () {
    late TelemetryTestHarness harness;
    late _SftpFixture fixture;

    setUp(() {
      harness = TelemetryTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
      await SftpFileCache.clearAll();
    });

    test(
      'downloadBytes emits started then completed with shared traceId',
      () async {
        fixture = _SftpFixture(
          harness: harness,
          bytes: Uint8List.fromList('hello world'.codeUnits),
        );
        addTearDown(fixture.dispose);

        final result = await fixture.service.downloadBytes(
          fixture.entry,
          bypassCache: true,
        );

        expect(result, 'hello world'.codeUnits);
        final records = await harness.recordsByName();
        final started = records[TelemetryEvents.sftpTransferStarted.name];
        final completed = records[TelemetryEvents.sftpTransferCompleted.name];

        expect(started, hasLength(1));
        expect(completed, hasLength(1));

        final startedRecord = started!.single;
        final completedRecord = completed!.single;

        expect(completedRecord.traceId, startedRecord.traceId);
        expect(startedRecord.properties, containsPair('direction', 'download'));
        expect(startedRecord.properties, containsPair('file_size_bytes', 11));
        expect(
          completedRecord.properties,
          containsPair('direction', 'download'),
        );
        expect(
          completedRecord.properties,
          containsPair('bytes_transferred', 11),
        );
        expect(completedRecord.properties['duration_ms'], isA<int>());
      },
    );

    test(
      'failed download emits failed with mapped error code and stage',
      () async {
        fixture = _SftpFixture(
          harness: harness,
          bytes: Uint8List.fromList('data'.codeUnits),
          openError: StateError('Permission denied'),
        );
        addTearDown(fixture.dispose);

        await expectLater(
          fixture.service.downloadBytes(fixture.entry, bypassCache: true),
          throwsA(isA<StateError>()),
        );

        final records = await harness.recordsByName();
        final started = records[TelemetryEvents.sftpTransferStarted.name];
        final failed = records[TelemetryEvents.sftpTransferFailed.name];

        expect(started, hasLength(1));
        expect(failed, hasLength(1));

        final failedRecord = failed!.single;
        expect(failedRecord.traceId, started!.single.traceId);
        expect(
          failedRecord.error?.errorCode,
          TelemetryErrorCodes.sftpPermissionDenied.code,
        );
        expect(failedRecord.properties, containsPair('stage', 'download'));
        expect(failedRecord.properties, containsPair('direction', 'download'));
        expect(failedRecord.properties['bytes_transferred'], isA<int>());
      },
    );

    test(
      'uploadBytes emits started then completed with shared traceId',
      () async {
        fixture = _SftpFixture(
          harness: harness,
          bytes: Uint8List.fromList('abc'.codeUnits),
        );
        addTearDown(fixture.dispose);

        await fixture.service.uploadBytes(
          filename: 'out.txt',
          bytes: Uint8List.fromList('abc'.codeUnits),
        );

        final records = await harness.recordsByName();
        final started = records[TelemetryEvents.sftpTransferStarted.name];
        final completed = records[TelemetryEvents.sftpTransferCompleted.name];

        final startedRecord = started!.single;
        final completedRecord = completed!.single;
        expect(completedRecord.traceId, startedRecord.traceId);
        expect(startedRecord.properties, containsPair('direction', 'upload'));
        expect(completedRecord.properties, containsPair('direction', 'upload'));
        expect(
          completedRecord.properties,
          containsPair('bytes_transferred', 3),
        );
      },
    );

    test(
      'bounds failure telemetry so the original transfer error returns promptly',
      () async {
        final storage = _BlockingTelemetryStorage();
        final client = TelemetryClient(
          config: const TelemetryClientConfig(
            baseUrl: 'https://relay.test',
            deviceId: 'test-device',
            appVersion: '1.0.0',
            buildNumber: '1',
            platform: 'linux',
            releaseChannel: 'test',
          ),
          storage: storage,
        );
        fixture = _SftpFixture(
          harness: harness,
          bytes: Uint8List.fromList('data'.codeUnits),
          openError: StateError('Permission denied'),
          telemetryFailureTimeout: Duration.zero,
        );
        fixture.service.telemetryClient = client;
        addTearDown(fixture.dispose);
        addTearDown(() async {
          storage.releaseWrites();
          await client.dispose();
        });

        final operation = fixture.service.downloadBytes(
          fixture.entry,
          bypassCache: true,
        );
        Object? operationError;
        var completed = false;
        final observed = operation.then<void>(
          (_) {
            completed = true;
          },
          onError: (Object error, StackTrace _) {
            operationError = error;
            completed = true;
          },
        );
        await storage.insertStarted.future;
        await Future<void>.delayed(Duration.zero);

        expect(completed, isTrue);
        expect(operationError, isA<StateError>());

        storage.releaseWrites();
        await observed;
      },
    );
  });
}

class _SftpFixture {
  _SftpFixture({
    required TelemetryTestHarness harness,
    required Uint8List bytes,
    Object? openError,
    Duration? telemetryFailureTimeout,
  }) : connection = ConnectionConfig(
         id: 'server-1',
         name: 'server-1',
         host: 'one.example.com',
         username: 'tester',
       ),
       storage = _NoopStorageService(),
       remote = _MemorySftpClient(bytes, openError: openError) {
    final binding = ConnectionTargetBinding.fromConfig(connection);
    targetFingerprint = binding.fingerprint;
    service = SftpService.forTesting(
      storage.connectionRepository,
      storage.credentialRepository,
      storage.hostKeyRepository,
      connection: connection,
      sftpClient: remote,
      currentPath: '/srv',
      telemetryFailureTimeout:
          telemetryFailureTimeout ?? const Duration(milliseconds: 250),
    );
    service.telemetryClient = harness.client;
    entry = SftpEntry(
      connectionId: connection.id,
      targetFingerprint: targetFingerprint,
      name: 'demo.txt',
      path: '/srv/demo.txt',
      lowerName: 'demo.txt',
      isDirectory: false,
      isLink: false,
      size: bytes.length,
      sizeLabel: '${bytes.length} B',
      modifiedAt: DateTime.utc(2026, 7, 14),
    );
  }

  final ConnectionConfig connection;
  final _MemorySftpClient remote;
  final _NoopStorageService storage;
  late final String targetFingerprint;
  late final SftpService service;
  late final SftpEntry entry;

  void dispose() {
    service.dispose();
    storage.dispose();
  }
}

final class _BlockingTelemetryStorage extends MemoryTelemetryStorage {
  final Completer<void> insertStarted = Completer<void>();
  final Completer<void> _writeRelease = Completer<void>();

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    if (!insertStarted.isCompleted) insertStarted.complete();
    await _writeRelease.future;
    await super.insertRecord(record);
  }

  void releaseWrites() {
    if (!_writeRelease.isCompleted) _writeRelease.complete();
  }
}

class _NoopStorageService extends TestStorageAdapter {
  @override
  Future<void> recordVisitedPath(String connectionId, String path) async {}
}

final class _MemorySftpClient implements SftpClient {
  _MemorySftpClient(this.bytes, {this.openError});

  Uint8List bytes;
  final Object? openError;

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    if (openError != null) throw openError!;
    return _MemorySftpFile(this, path);
  }

  @override
  Future<String> absolute(String path) async => path;

  @override
  Future<List<SftpName>> listdir(String path) async => const [];

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP client call: $invocation');
}

final class _MemorySftpFile implements SftpFile {
  _MemorySftpFile(this.client, this.path);

  final _MemorySftpClient client;
  final String path;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    if (_isClosed) throw StateError('File is closed');
    if (offset >= client.bytes.length) return Uint8List(0);
    final end = (offset + (length ?? client.bytes.length)) < client.bytes.length
        ? offset + (length ?? client.bytes.length)
        : client.bytes.length;
    return Uint8List.sublistView(client.bytes, offset, end);
  }

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    if (offset == 0) {
      client.bytes = Uint8List.fromList(data);
    } else {
      final merged = Uint8List(offset + data.length)
        ..setAll(0, client.bytes)
        ..setAll(offset, data);
      client.bytes = merged;
    }
  }

  @override
  Future<void> close() async {
    _isClosed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected SFTP file call: $invocation');
}
