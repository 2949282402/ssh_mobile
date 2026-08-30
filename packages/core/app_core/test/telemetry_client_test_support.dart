import 'package:app_core/app_core.dart';

TelemetryEventRecord persistedDiagnosticRecord({
  required String eventId,
  required String message,
  String eventName = 'app.diagnostic.log',
}) {
  return TelemetryEventRecord(
    eventId: eventId,
    recordType: TelemetryRecordType.diagnostic,
    eventName: eventName,
    eventVersion: 1,
    deviceId: 'dev-client-1',
    sessionId: 'sess-fixed',
    traceId: 'trace-persisted',
    occurredAt: DateTime.utc(2026, 8, 28),
    feature: 'app',
    severity: TelemetrySeverity.warn,
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'android',
    properties: {'message': message},
  );
}

final class TestTelemetryStorage implements TelemetryStorage {
  TestTelemetryStorage([Iterable<TelemetryEventRecord>? records])
    : records = List<TelemetryEventRecord>.from(records ?? const []);

  final List<TelemetryEventRecord> records;
  bool failFetchPending = false;
  bool failApplyAck = false;
  bool failRetryCount = false;
  bool closed = false;

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    if (closed) throw StateError('closed');
    records.add(record);
  }

  @override
  Future<List<TelemetryEventRecord>> fetchPendingBatch(int limit) async {
    if (failFetchPending) throw StateError('pending read failed');
    if (closed) throw StateError('closed');
    return records
        .where((record) => record.syncState == TelemetrySyncState.pending)
        .take(limit > 0 ? limit : 50)
        .toList();
  }

  @override
  Future<void> applyAckResults(List<TelemetryAckResult> results) async {
    if (failApplyAck) throw StateError('ack write failed');
    if (closed) throw StateError('closed');
    final byId = {for (final result in results) result.eventId: result};
    for (var i = 0; i < records.length; i++) {
      final result = byId[records[i].eventId];
      if (result == null) continue;
      records[i] = records[i].copyWith(
        syncState: result.isRejected
            ? TelemetrySyncState.rejected
            : TelemetrySyncState.synced,
        logicalDeletedAt: result.isRejected ? null : DateTime.utc(2026, 8, 28),
        clearLogicalDeletedAt: result.isRejected,
      );
    }
  }

  @override
  Future<void> applyRetryCount(
    List<String> eventIds, {
    required int increment,
  }) async {
    if (failRetryCount) throw StateError('retry write failed');
    if (closed) throw StateError('closed');
    final ids = eventIds.toSet();
    for (var i = 0; i < records.length; i++) {
      if (ids.contains(records[i].eventId)) {
        records[i] = records[i].copyWith(
          retryCount: records[i].retryCount + increment,
        );
      }
    }
  }

  @override
  Future<List<TelemetryEventRecord>> fetchAllForReplay() async =>
      List<TelemetryEventRecord>.unmodifiable(records);

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async => 0;

  @override
  Future<TelemetryStorageHealth> getHealthStats({
    required int targetCapacity,
  }) async {
    return TelemetryStorageHealth(
      localPendingCount: records
          .where((record) => record.syncState == TelemetrySyncState.pending)
          .length,
      localRejectedCount: records
          .where((record) => record.syncState == TelemetrySyncState.rejected)
          .length,
      localSyncedCount: records
          .where((record) => record.syncState == TelemetrySyncState.synced)
          .length,
      totalCount: records.length,
      cacheOverflow: records.length > targetCapacity,
    );
  }

  @override
  TelemetryStorageHealth? get cachedHealthStats => null;

  @override
  Future<void> clearAll() async => records.clear();

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class TestTelemetryTransport implements TelemetryTransport {
  String token = 'mock-test-token-123';
  TelemetryUploadPolicy? remotePolicy;
  final List<List<TelemetryEventRecord>> uploadedBatches = [];
  final List<TelemetryAckResult> nextAckResults = [];
  TelemetryBatchUploadResult? uploadResultOverride;
  final List<int> nextUploadStatusCodes = [];
  final List<int?> nextRetryAfters = [];

  bool shouldFailAuth = false;
  TelemetryAuthResult? authResultOverride;
  bool shouldFailUpload = false;
  Object? uploadFailure;
  bool shouldFailPolicy = false;
  int authCalls = 0;
  int uploadCalls = 0;
  int policyCalls = 0;
  final List<int?> authExpEpochs = [];
  bool authRepeatedAfter401 = false;

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async {
    authCalls++;
    authExpEpochs.add(expEpoch);
    if (authRepeatedAfter401 && authCalls >= 2) {
      return TelemetryAuthResult(token: token, expiresInSeconds: 2 * 60 * 60);
    }
    if (authResultOverride != null) return authResultOverride!;
    if (shouldFailAuth) {
      throw const TelemetryUploadException(
        'Network auth failure',
        statusCode: 401,
      );
    }
    return TelemetryAuthResult(token: token, expiresInSeconds: 2 * 60 * 60);
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
  }) async {
    policyCalls++;
    if (shouldFailPolicy) {
      throw const TelemetryUploadException(
        'Network policy fetch failure',
        statusCode: 503,
      );
    }
    return remotePolicy ?? TelemetryUploadPolicy.defaultPolicy();
  }

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    uploadCalls++;
    if (uploadFailure != null) throw uploadFailure!;
    if (shouldFailUpload) {
      throw const TelemetryUploadException(
        'Network upload failure',
        statusCode: 503,
      );
    }

    int? statusCode;
    int? retryAfter;
    if (nextUploadStatusCodes.isNotEmpty) {
      statusCode = nextUploadStatusCodes.removeAt(0);
      if (nextRetryAfters.isNotEmpty) {
        retryAfter = nextRetryAfters.removeAt(0);
      }
    }
    if (statusCode != null && statusCode != 200) {
      throw TelemetryUploadException(
        'Simulated upload failure with status $statusCode',
        statusCode: statusCode,
        retryAfterSeconds: retryAfter,
      );
    }

    uploadedBatches.add(List.from(records));
    if (uploadResultOverride != null) {
      final override = uploadResultOverride!;
      uploadResultOverride = null;
      return override;
    }
    if (nextAckResults.isNotEmpty) {
      final results = List<TelemetryAckResult>.from(nextAckResults);
      nextAckResults.clear();
      return TelemetryBatchUploadResult(ackResults: results);
    }
    return TelemetryBatchUploadResult(
      ackResults: records
          .map(
            (r) => TelemetryAckResult(eventId: r.eventId, status: 'accepted'),
          )
          .toList(),
    );
  }
}

TelemetryClient buildTestTelemetryClient({
  required TelemetryStorage storage,
  required TestTelemetryTransport transport,
  TelemetryUploadPolicy? initialPolicy,
  String? deviceEnrollmentSecret = 'test-secret-123',
}) {
  return TelemetryClient(
    config: TelemetryClientConfig(
      baseUrl: 'http://127.0.0.1:8080',
      deviceId: 'dev-client-1',
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android',
      releaseChannel: 'beta',
      telemetryEnabled: true,
      sessionId: 'sess-fixed',
      deviceEnrollmentSecret: deviceEnrollmentSecret,
      authTokenTtlSeconds: 2 * 60 * 60,
      policyFetchIntervalSeconds: 0,
    ),
    storage: storage,
    transport: transport,
    initialPolicy:
        initialPolicy ??
        const TelemetryUploadPolicy(
          uploadEnabled: true,
          batchSizeThreshold: 2,
          timeIntervalSeconds: 60,
          maxBatchSize: 10,
          clientMaxLocalRecords: 100,
          specialTriggers: [
            'highPriorityError',
            'appBackground',
            'networkRecovered',
            'appForegroundWithBacklog',
          ],
          policyVersion: 1,
        ),
  );
}
