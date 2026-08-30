import 'dart:async';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

import 'telemetry/telemetry_test_utils.dart';
import 'sftp_transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    // The path-provider mock below also serves AppLogService's application
    // support directory. Drain and detach the previous test's log file before
    // switching to a new temporary directory.
    await AppLogService.instance.pendingWrites;
    AppLogService.instance.resetLogFileForTesting();
    tempDir = await Directory.systemTemp.createTemp(
      'ssh-mobile-sftp-telemetry-',
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
    await AppLogService.instance.pendingWrites;
    AppLogService.instance.resetLogFileForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('records started and completed spans for download and upload', () async {
    final telemetry = TelemetryTestHarness();
    final connection = makeConnection('telemetry-success');
    final remote = MemorySftpClient()
      ..setFile('/srv/demo.bin', Uint8List.fromList('remote'.codeUnits));
    final fixture = TransferFixture(
      connection: connection,
      remote: remote,
      entry: makeFileEntry(connection, 'demo.bin', size: 6),
      telemetryClient: telemetry.client,
    );
    addTearDown(() async {
      fixture.dispose();
      await telemetry.dispose();
    });

    await fixture.service.downloadBytes(fixture.entry, bypassCache: true);
    await fixture.service.uploadBytes(
      filename: 'uploaded.bin',
      bytes: Uint8List.fromList('upload'.codeUnits),
    );
    await _drainTelemetry();

    final records = await telemetry.replayRecords();
    final started = records
        .where(
          (record) =>
              record.eventName == TelemetryEvents.sftpTransferStarted.name,
        )
        .toList();
    final completed = records
        .where(
          (record) =>
              record.eventName == TelemetryEvents.sftpTransferCompleted.name,
        )
        .toList();
    expect(started, hasLength(2));
    expect(completed, hasLength(2));
    expect(
      started.map((record) => record.properties['direction']),
      containsAll(<String>['download', 'upload']),
    );
    expect(
      completed.map((record) => record.properties['bytes_transferred']),
      containsAll(<int>[6, 6]),
    );
    expect(started.map((record) => record.traceId).toSet(), hasLength(2));
  });

  test('maps upload and download failures to stable telemetry codes', () async {
    final telemetry = TelemetryTestHarness();
    final connection = makeConnection('telemetry-failure');
    final remote = MemorySftpClient()
      ..setFile('/srv/demo.bin', Uint8List.fromList('data'.codeUnits));
    final fixture = TransferFixture(
      connection: connection,
      remote: remote,
      entry: makeFileEntry(connection, 'demo.bin', size: 4),
      telemetryClient: telemetry.client,
    );
    addTearDown(() async {
      fixture.dispose();
      await telemetry.dispose();
    });

    final errors = <String>[
      'Permission denied',
      'No such file',
      'quota exceeded',
      'operation cancelled',
      'unexpected transport failure',
    ];
    for (final message in errors) {
      remote.openError = StateError(message);
      await expectLater(
        fixture.service.uploadBytes(
          filename: 'failed.bin',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
        throwsA(isA<StateError>()),
      );
    }
    remote.openError = StateError('Permission denied');
    await expectLater(
      fixture.service.downloadBytes(fixture.entry, bypassCache: true),
      throwsA(isA<StateError>()),
    );
    await _drainTelemetry();

    final failed = (await telemetry.replayRecords())
        .where(
          (record) =>
              record.eventName == TelemetryEvents.sftpTransferFailed.name,
        )
        .toList();
    expect(failed, hasLength(6));
    expect(
      failed.map((record) => record.error?.errorCode),
      containsAll(<String>[
        TelemetryErrorCodes.sftpPermissionDenied.code,
        TelemetryErrorCodes.sftpFileNotFound.code,
        TelemetryErrorCodes.sftpQuotaExceeded.code,
        TelemetryErrorCodes.sftpTransferAborted.code,
        TelemetryErrorCodes.sftpOperationFailed.code,
      ]),
    );
  });

  test('records cancellation as an aborted upload span', () async {
    final telemetry = TelemetryTestHarness();
    final connection = makeConnection('telemetry-cancel');
    final remote = MemorySftpClient()..setListing('/srv', const []);
    remote.writeGate = Completer<void>();
    final fixture = TransferFixture(
      connection: connection,
      remote: remote,
      entry: makeFileEntry(connection, 'cancel.bin', size: 300 * 1024),
      telemetryClient: telemetry.client,
    );
    addTearDown(() async {
      fixture.dispose();
      await telemetry.dispose();
    });
    final localPath = '${tempDir.path}/cancel.bin';
    await File(localPath).writeAsBytes(List<int>.filled(300 * 1024, 5));

    final operation = fixture.service.uploadFile(
      localPath: localPath,
      filename: 'cancel.bin',
    );
    await remote.writeStarted.future;
    fixture.service.cancelActiveTransfer();
    remote.writeGate!.complete();
    await expectLater(
      operation,
      throwsA(isA<SftpTransferCancelledException>()),
    );
    await _drainTelemetry();

    final failed = (await telemetry.replayRecords())
        .where(
          (record) =>
              record.eventName == TelemetryEvents.sftpTransferFailed.name,
        )
        .single;
    expect(
      failed.error?.errorCode,
      TelemetryErrorCodes.sftpTransferAborted.code,
    );
  });
}

Future<void> _drainTelemetry() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}
