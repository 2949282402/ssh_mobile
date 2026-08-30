import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'dispose drains authentication and ACK storage work and is idempotent',
    () async {
      final storage = _LifecycleStorage(ackGate: Completer<void>());
      final transport = _BlockingTelemetryTransport();
      final client = _buildClient(storage: storage, transport: transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      final flush = client.flush();
      await transport.authStarted.future;

      final firstDispose = client.dispose();
      final secondDispose = client.dispose();
      expect(identical(firstDispose, secondDispose), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(storage.closeCalls, 0);

      transport.authRelease.complete();
      await transport.uploadStarted.future;
      expect(storage.closeCalls, 0);

      storage.ackGate!.complete();
      transport.uploadRelease.complete();
      await flush;
      await firstDispose;

      expect(storage.closeCalls, 1);
      expect(storage.accessAfterClose, isFalse);
      expect(storage.ackCalls, 1);
      expect(
        (await storage.snapshot()).single.syncState,
        TelemetrySyncState.synced,
      );

      await client.dispose();
      expect(storage.closeCalls, 1);
    },
  );

  test(
    'dispose drains retry persistence and preserves the upload error',
    () async {
      final storage = _LifecycleStorage(retryGate: Completer<void>());
      final client = _buildClient(
        storage: storage,
        transport: _FailingUploadTelemetryTransport(),
      );

      await client.record(event: TelemetryEvents.sshSessionStarted);
      final flush = client.flush();
      await storage.retryStarted.future;

      final disposing = client.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(storage.closeCalls, 0);

      storage.retryGate!.complete();
      await flush;
      await disposing;

      expect(storage.closeCalls, 1);
      expect(storage.accessAfterClose, isFalse);
      expect(storage.retryCalls, 1);
      expect(client.latestDiagnostics.lastSyncError, contains('HTTP 503'));
    },
  );
}

TelemetryClient _buildClient({
  required TelemetryStorage storage,
  required TelemetryTransport transport,
}) => TelemetryClient(
  config: const TelemetryClientConfig(
    baseUrl: 'https://relay.example.test',
    deviceId: 'device-lifecycle',
    appVersion: '1.0.0',
    buildNumber: '1',
    platform: 'linux',
    releaseChannel: 'test',
    telemetryEnabled: true,
    deviceEnrollmentSecret: 'lifecycle-enrollment-secret',
    policyFetchIntervalSeconds: 0,
  ),
  storage: storage,
  transport: transport,
  initialPolicy: const TelemetryUploadPolicy(
    uploadEnabled: true,
    batchSizeThreshold: 100,
    timeIntervalSeconds: 3600,
    maxBatchSize: 10,
    clientMaxLocalRecords: 100,
    specialTriggers: <String>[],
    policyVersion: 1,
  ),
);

final class _BlockingTelemetryTransport implements TelemetryTransport {
  final Completer<void> authStarted = Completer<void>();
  final Completer<void> authRelease = Completer<void>();
  final Completer<void> uploadStarted = Completer<void>();
  final Completer<void> uploadRelease = Completer<void>();

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async {
    authStarted.complete();
    await authRelease.future;
    return const TelemetryAuthResult(
      token: 'lifecycle-token',
      expiresInSeconds: 3600,
    );
  }

  @override
  Future<TelemetryEnrollmentResult?> enrollDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async => null;

  @override
  Future<TelemetryEnrollmentResult?> rotateDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async => null;

  @override
  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  }) async => TelemetryUploadPolicy.defaultPolicy();

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    uploadStarted.complete();
    await uploadRelease.future;
    return TelemetryBatchUploadResult(
      ackResults: [
        for (final record in records)
          TelemetryAckResult(eventId: record.eventId, status: 'accepted'),
      ],
    );
  }
}

final class _FailingUploadTelemetryTransport implements TelemetryTransport {
  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async =>
      const TelemetryAuthResult(token: 'failure-token', expiresInSeconds: 3600);

  @override
  Future<TelemetryEnrollmentResult?> enrollDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async => null;

  @override
  Future<TelemetryEnrollmentResult?> rotateDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async => null;

  @override
  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  }) async => TelemetryUploadPolicy.defaultPolicy();

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    throw const TelemetryUploadException(
      'Telemetry upload failed',
      statusCode: 503,
    );
  }
}

final class _LifecycleStorage implements TelemetryStorage {
  _LifecycleStorage({this.ackGate, this.retryGate});

  final MemoryTelemetryStorage _inner = MemoryTelemetryStorage();
  final Completer<void>? ackGate;
  final Completer<void>? retryGate;
  final Completer<void> retryStarted = Completer<void>();
  bool closed = false;
  bool accessAfterClose = false;
  int closeCalls = 0;
  int ackCalls = 0;
  int retryCalls = 0;

  void _checkOpen() {
    if (closed) {
      accessAfterClose = true;
      throw StateError('storage accessed after close');
    }
  }

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    _checkOpen();
    await _inner.insertRecord(record);
  }

  @override
  Future<List<TelemetryEventRecord>> fetchPendingBatch(int limit) async {
    _checkOpen();
    return _inner.fetchPendingBatch(limit);
  }

  @override
  Future<void> applyAckResults(List<TelemetryAckResult> results) async {
    _checkOpen();
    ackCalls++;
    if (ackGate != null) await ackGate!.future;
    _checkOpen();
    await _inner.applyAckResults(results);
  }

  @override
  Future<void> applyRetryCount(
    List<String> eventIds, {
    required int increment,
  }) async {
    _checkOpen();
    retryCalls++;
    retryStarted.complete();
    if (retryGate != null) await retryGate!.future;
    _checkOpen();
    await _inner.applyRetryCount(eventIds, increment: increment);
  }

  @override
  Future<List<TelemetryEventRecord>> fetchAllForReplay() async {
    _checkOpen();
    return _inner.fetchAllForReplay();
  }

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async {
    _checkOpen();
    return _inner.purgeOldSyncedRecords(targetCapacity: targetCapacity);
  }

  @override
  Future<TelemetryStorageHealth> getHealthStats({
    required int targetCapacity,
  }) async {
    _checkOpen();
    return _inner.getHealthStats(targetCapacity: targetCapacity);
  }

  @override
  TelemetryStorageHealth? get cachedHealthStats => _inner.cachedHealthStats;

  @override
  Future<void> clearAll() async {
    _checkOpen();
    await _inner.clearAll();
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    closeCalls++;
    await _inner.close();
  }

  Future<List<TelemetryEventRecord>> snapshot() => _inner.fetchAllForReplay();
}
