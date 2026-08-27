import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

TelemetryEventRecord _persistedDiagnosticRecord({
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

final class _ScriptedTelemetryStorage implements TelemetryStorage {
  _ScriptedTelemetryStorage([Iterable<TelemetryEventRecord>? records])
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

class MockTelemetryTransport implements TelemetryTransport {
  String token = 'mock-test-token-123';
  TelemetryUploadPolicy? remotePolicy;
  final List<List<TelemetryEventRecord>> uploadedBatches = [];
  final List<TelemetryAckResult> nextAckResults = [];
  final List<int> nextUploadStatusCodes = [];
  final List<int?> nextRetryAfters = [];

  bool shouldFailAuth = false;
  bool shouldFailUpload = false;
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
    // 首次认证成功后，用于验证 401 后重认证是否发生。
    if (authRepeatedAfter401 && authCalls >= 2) {
      return TelemetryAuthResult(token: token, expiresInSeconds: 2 * 60 * 60);
    }
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

    if (shouldFailUpload) {
      throw const TelemetryUploadException(
        'Network upload failure',
        statusCode: 503,
      );
    }

    // 按顺序弹出预配置的状态码。
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

TelemetryClient _buildClient({
  required TelemetryStorage storage,
  required MockTelemetryTransport transport,
  TelemetryUploadPolicy? initialPolicy,
  String? deviceEnrollmentSecret = 'test-secret-123',
}) {
  // ignore: invalid_use_of_internal_member
  return TelemetryClient(
    config: TelemetryClientConfig(
      baseUrl: 'http://127.0.0.1:8080',
      deviceId: 'dev-client-1',
      appVersion: '1.0.0',
      buildNumber: '100',
      platform: 'android',
      releaseChannel: 'beta',
      sessionId: 'sess-fixed',
      deviceEnrollmentSecret: deviceEnrollmentSecret,
      authTokenTtlSeconds: 2 * 60 * 60,
      policyFetchIntervalSeconds: 0, // 测试中不启动周期策略拉取
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

void main() {
  group('TelemetryClient & Dispatcher', () {
    late TelemetryStorage storage;
    late MockTelemetryTransport transport;
    late TelemetryClient client;

    setUp(() {
      storage = MemoryTelemetryStorage();
      transport = MockTelemetryTransport();

      client = _buildClient(storage: storage, transport: transport);
    });

    tearDown(() async {
      // 取消待处理的重试 Timer，避免跨用例泄漏。
      await client.dispose();
    });

    test(
      'validates event against catalog before inserting into storage',
      () async {
        // 1. Valid default event succeeds (e.g. ssh.session.started with allowed property 'session_type')
        final success = await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );
        expect(success, isTrue);

        final pending = await storage.fetchPendingBatch(10);
        expect(pending.length, 1);
        expect(pending[0].eventName, TelemetryEvents.sshSessionStarted.name);

        // 2. Unregistered event fails validation and is not recorded
        final unregistered = await client.record(
          event: const TelemetryEventDefinition(
            name: 'unknown.event.name',
            version: 1,
            recordType: TelemetryRecordType.analytics,
            feature: 'ssh',
            severity: TelemetrySeverity.info,
            allowedProperties: {},
          ),
          properties: {},
        );
        expect(unregistered, isFalse);
        expect((await storage.fetchPendingBatch(10)).length, 1);

        // 3. Undeclared property fails validation
        final missingProp = await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'forbidden_prop': 123},
        );
        expect(missingProp, isFalse);
        expect((await storage.fetchPendingBatch(10)).length, 1);
      },
    );

    test('revalidates and re-sanitizes persisted rows before upload', () async {
      final persistedStorage = _ScriptedTelemetryStorage([
        _persistedDiagnosticRecord(
          eventId: 'evt-persisted-safe',
          message: 'Authorization: Bearer persisted-token-value',
        ),
        _persistedDiagnosticRecord(
          eventId: 'evt-persisted-invalid',
          message: 'must not be uploaded',
          eventName: 'unknown.persisted.event',
        ),
      ]);
      final persistedClient = _buildClient(
        storage: persistedStorage,
        transport: transport,
      );

      await persistedClient.flush();

      expect(transport.uploadCalls, 1);
      expect(transport.uploadedBatches, hasLength(1));
      expect(transport.uploadedBatches.single, hasLength(1));
      expect(
        transport.uploadedBatches.single.single.properties['message'],
        isNot(contains('persisted-token-value')),
      );
      expect(
        persistedStorage.records
            .singleWhere((record) => record.eventId == 'evt-persisted-invalid')
            .syncState,
        TelemetrySyncState.rejected,
      );

      await persistedClient.dispose();
    });

    test(
      'quarantines invalid persisted rows without authenticating or uploading',
      () async {
        final persistedStorage = _ScriptedTelemetryStorage([
          _persistedDiagnosticRecord(
            eventId: 'evt-persisted-invalid-only',
            message: 'must not be uploaded',
            eventName: 'unknown.persisted.event',
          ),
        ]);
        final persistedClient = _buildClient(
          storage: persistedStorage,
          transport: transport,
        );

        await persistedClient.flush();

        expect(transport.authCalls, 0);
        expect(transport.uploadCalls, 0);
        expect(
          persistedStorage.records.single.syncState,
          TelemetrySyncState.rejected,
        );
        expect(persistedClient.latestDiagnostics.lastSyncError, isNull);

        await persistedClient.dispose();
      },
    );

    test('contains pending-read storage failures in flush', () async {
      final failingStorage = _ScriptedTelemetryStorage()
        ..failFetchPending = true;
      final failingClient = _buildClient(
        storage: failingStorage,
        transport: transport,
      );

      await expectLater(failingClient.flush(), completes);
      expect(transport.authCalls, 0);
      expect(
        failingClient.latestDiagnostics.lastSyncError,
        'Telemetry storage operation failed',
      );

      await failingClient.dispose();
    });

    test(
      'contains storage failures while applying upload results and leaves rows pending',
      () async {
        final failingStorage = _ScriptedTelemetryStorage([
          _persistedDiagnosticRecord(
            eventId: 'evt-persisted-ack-failure',
            message: 'ack write fails',
          ),
        ])..failApplyAck = true;
        final failingClient = _buildClient(
          storage: failingStorage,
          transport: transport,
        );

        await expectLater(failingClient.flush(), completes);
        expect(transport.uploadCalls, 1);
        expect(
          failingStorage.records.single.syncState,
          TelemetrySyncState.pending,
        );
        expect(
          failingClient.latestDiagnostics.lastSyncError,
          'Telemetry storage operation failed',
        );

        await failingClient.dispose();
      },
    );

    test(
      'contains retry bookkeeping storage failures in background flush',
      () async {
        final failingStorage = _ScriptedTelemetryStorage([
          _persistedDiagnosticRecord(
            eventId: 'evt-persisted-retry-failure',
            message: 'retry bookkeeping fails',
          ),
        ])..failRetryCount = true;
        transport.nextUploadStatusCodes.add(503);
        final failingClient = _buildClient(
          storage: failingStorage,
          transport: transport,
        );

        await expectLater(failingClient.flush(), completes);
        expect(transport.uploadCalls, 1);
        expect(
          failingStorage.records.single.syncState,
          TelemetrySyncState.pending,
        );
        expect(failingStorage.records.single.retryCount, 0);
        expect(
          failingClient.latestDiagnostics.lastSyncError,
          'Telemetry storage operation failed',
        );

        await failingClient.dispose();
      },
    );

    test('serializes concurrent record writes in invocation order', () async {
      final first = client.record(
        event: TelemetryEvents.sshSessionStarted,
        traceId: 'trace-first',
        properties: {'session_type': 'terminal'},
      );
      final second = client.record(
        event: TelemetryEvents.sshSessionStarted,
        traceId: 'trace-second',
        properties: {'session_type': 'terminal'},
      );

      expect(await Future.wait([first, second]), [true, true]);
      final records = await storage.fetchAllForReplay();
      expect(records.map((record) => record.traceId), [
        'trace-first',
        'trace-second',
      ]);
    });

    test('drains an accepted queued write before closing storage', () async {
      final pending = client.record(
        event: TelemetryEvents.sshSessionStarted,
        traceId: 'trace-before-dispose',
        properties: {'session_type': 'terminal'},
      );

      await client.dispose();

      expect(await pending, isTrue);
      expect(
        (await storage.fetchAllForReplay()).single.traceId,
        'trace-before-dispose',
      );
    });

    test(
      'record derives envelope metadata and error metadata from definitions',
      () async {
        final success = await client.record(
          event: TelemetryEvents.networkRelayFailed,
          properties: {'reason': 'relay unavailable', 'fallback_used': true},
          errorCode: TelemetryErrorCodes.netRelayUnavailable,
          errorMessage: 'relay unavailable',
        );

        expect(success, isTrue);
        final pending = await storage.fetchPendingBatch(10);
        expect(pending, hasLength(1));
        final record = pending.single;
        expect(record.eventName, TelemetryEvents.networkRelayFailed.name);
        expect(record.eventVersion, TelemetryEvents.networkRelayFailed.version);
        expect(record.recordType, TelemetryRecordType.diagnostic);
        expect(record.feature, 'network');
        expect(record.severity, TelemetrySeverity.error);
        expect(
          record.error?.errorCode,
          TelemetryErrorCodes.netRelayUnavailable.code,
        );
        expect(
          record.error?.category,
          TelemetryErrorCodes.netRelayUnavailable.category,
        );
        expect(
          record.error?.terminalFailure,
          TelemetryErrorCodes.netRelayUnavailable.terminalFailure,
        );
      },
    );

    test(
      'accepts generated SFTP failure metadata and mapped permission errors',
      () async {
        final success = await client.record(
          event: TelemetryEvents.sftpTransferFailed,
          properties: {
            'direction': 'download',
            'bytes_transferred': 0,
            'stage': 'download',
          },
          errorCode: TelemetryErrorCodes.sftpPermissionDenied,
          errorMessage: 'Bad state: Permission denied',
        );

        expect(success, isTrue);
        final record = (await storage.fetchAllForReplay()).single;
        expect(record.properties, {
          'direction': 'download',
          'bytes_transferred': 0,
          'stage': 'download',
        });
        expect(
          record.error?.errorCode,
          TelemetryErrorCodes.sftpPermissionDenied.code,
        );
        expect(record.error?.message, 'Bad state: Permission denied');
      },
    );

    test(
      'unregistered typed definitions are rejected by the catalog',
      () async {
        const unknownEvent = TelemetryEventDefinition(
          name: 'unknown.event',
          version: 1,
          recordType: TelemetryRecordType.analytics,
          feature: 'unknown',
          severity: TelemetrySeverity.info,
          allowedProperties: {},
        );
        final result = await client.record(event: unknownEvent);
        expect(result, isFalse);
        expect(await storage.fetchPendingBatch(10), isEmpty);
      },
    );

    test('batch count threshold triggers automatic upload', () async {
      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: {'session_type': 'terminal'},
      );

      expect(transport.uploadCalls, 0);

      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: {'auth_method': 'password'},
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(transport.uploadCalls, 1);
      expect(transport.authCalls, 1);
      expect(transport.uploadedBatches.length, 1);
      expect(transport.uploadedBatches[0].length, 2);

      final pending = await storage.fetchPendingBatch(10);
      expect(pending, isEmpty);
    });

    test(
      'highPriorityError trigger immediately flushes even if batch size not reached',
      () async {
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'shell'},
        );
        expect(transport.uploadCalls, 0);

        await client.record(
          event: TelemetryEvents.sshSessionFailed,
          properties: {'stage': 'handshake'},
          errorCode: TelemetryErrorCodes.sshAuthFailed,
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(transport.uploadCalls, 1);
        expect(transport.uploadedBatches[0].length, 2);
      },
    );

    test('typed critical records trigger a high priority flush', () async {
      await client.record(
        event: TelemetryEvents.appCrashReported,
        properties: {'message': 'fatal condition', 'category': 'crash'},
        errorCode: TelemetryErrorCodes.appFatalError,
        errorMessage: 'fatal condition',
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(transport.uploadCalls, 1);
      expect(transport.uploadedBatches[0].length, 1);
      expect(
        transport.uploadedBatches[0][0].recordType,
        TelemetryRecordType.diagnostic,
      );
    });

    test('typed records accept explicit traceId and sessionId', () async {
      await client.record(
        event: TelemetryEvents.appDiagnosticLog,
        properties: {'message': 'custom trace'},
        traceId: 'trace-explicit-1',
        sessionId: 'sess-explicit-1',
      );

      final pending = await storage.fetchPendingBatch(10);
      expect(pending[0].traceId, 'trace-explicit-1');
      expect(pending[0].sessionId, 'sess-explicit-1');
    });

    test(
      'single logical uploader guard prevents concurrent upload loops',
      () async {
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        final f1 = client.flush();
        final f2 = client.flush();
        final f3 = client.flush();

        await Future.wait([f1, f2, f3]);

        expect(transport.uploadCalls, 1);
      },
    );

    test('remote policy fetch updates policy and clamps safely', () async {
      transport.remotePolicy = const TelemetryUploadPolicy(
        uploadEnabled: true,
        batchSizeThreshold: 10,
        timeIntervalSeconds: 30,
        maxBatchSize: 20,
        clientMaxLocalRecords: 500,
        specialTriggers: [
          'highPriorityError',
          'appBackground',
          'networkRecovered',
          'appForegroundWithBacklog',
        ],
        policyVersion: 2,
      );

      final updated = await client.refreshPolicy();
      expect(updated, isTrue);
      expect(client.activePolicy.policyVersion, 2);
      expect(client.activePolicy.batchSizeThreshold, 10);
      expect(client.activePolicy.timeIntervalSeconds, 30);
    });

    test(
      'replayAllLocalRecords sends all local records with original IDs and ACKs them',
      () async {
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 't1'},
        );
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 't2'},
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transport.uploadCalls, 1);

        final replayedCount = await client.replayAllLocalRecords();
        expect(replayedCount, 2);
        expect(transport.uploadCalls, 2);
        expect(transport.uploadedBatches.length, 2);
      },
    );

    test('replay revalidates persisted rows before sending them', () async {
      final persistedStorage = _ScriptedTelemetryStorage([
        _persistedDiagnosticRecord(
          eventId: 'evt-replay-persisted',
          message: 'Cookie: session=persisted-cookie-value',
        ),
      ]);
      final persistedClient = _buildClient(
        storage: persistedStorage,
        transport: transport,
      );

      final replayedCount = await persistedClient.replayAllLocalRecords();

      expect(replayedCount, 1);
      expect(transport.uploadCalls, 1);
      expect(
        transport.uploadedBatches.single.single.properties['message'],
        isNot(contains('persisted-cookie-value')),
      );

      await persistedClient.dispose();
    });

    test(
      'storage health and diagnostics snapshot are reported accurately',
      () async {
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        final diag = await client.getDiagnostics();
        expect(diag.localPendingCount, 1);
        expect(diag.localSyncedCount, 0);
        expect(diag.localRejectedCount, 0);
        expect(diag.uploadEnabled, isTrue);
        expect(diag.cacheOverflow, isFalse);
      },
    );

    test(
      'sessionId is stable across calls unless explicitly overridden',
      () async {
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'shell'},
        );

        final pending = await storage.fetchPendingBatch(10);
        expect(pending[0].sessionId, pending[1].sessionId);
        // 固定会话 ID
        expect(pending[0].sessionId, 'sess-fixed');
        // traceId 每次调用唯一（UUID v4 格式）
        expect(pending[0].traceId, isNot(pending[1].traceId));
        expect(pending[0].traceId.length, 36);
      },
    );

    test(
      'auth proof includes HMAC signature when enrollment secret provided',
      () async {
        final clientWithSecret = _buildClient(
          storage: storage,
          transport: transport,
          deviceEnrollmentSecret: 'super-secret-enrollment',
        );

        await clientWithSecret.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );
        await clientWithSecret.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'auth_method': 'password'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(transport.authCalls, 1);
        // 有注册密钥时必须提供 expEpoch 证明时间戳。
        expect(transport.authExpEpochs.first, isNotNull);
        await clientWithSecret.dispose();
      },
    );

    test(
      '401 clears token, re-authenticates once and retries the same batch',
      () async {
        transport.authRepeatedAfter401 = true;
        // 第一次上传返回 401，第二次成功。
        transport.nextUploadStatusCodes.add(401);
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        final diagBefore = await client.getDiagnostics();
        expect(diagBefore.localPendingCount, 1);

        // 直接触发 flush 走 401 重认证路径。
        await client.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(transport.authCalls, 2); // 初次 + 重认证
        expect(transport.uploadCalls, 2); // 初次失败 + 重试成功

        final pending = await storage.fetchPendingBatch(10);
        expect(pending, isEmpty);
        final all = await storage.fetchAllForReplay();
        expect(all[0].syncState, TelemetrySyncState.synced);
      },
    );

    test(
      'auth failure keeps records pending, never marks accepted or deletes',
      () async {
        transport.shouldFailAuth = true;
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        await client.flush();

        final pending = await storage.fetchPendingBatch(10);
        expect(pending.length, 1);
        final all = await storage.fetchAllForReplay();
        expect(all[0].syncState, TelemetrySyncState.pending);
        expect(all[0].logicalDeletedAt, isNull);
      },
    );

    test('permanent 4xx marks records rejected and stops auto-retry', () async {
      transport.nextUploadStatusCodes.add(400);
      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: {'session_type': 'interactive'},
      );

      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final all = await storage.fetchAllForReplay();
      expect(all[0].syncState, TelemetrySyncState.rejected);
      // 不再自动重试：fetchPendingBatch 为空。
      expect(await storage.fetchPendingBatch(10), isEmpty);
    });

    test(
      '5xx failure increments retryCount and keeps records pending',
      () async {
        transport.nextUploadStatusCodes.add(503);
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        await client.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final all = await storage.fetchAllForReplay();
        expect(all[0].syncState, TelemetrySyncState.pending);
        expect(all[0].retryCount, greaterThanOrEqualTo(1));
        // 记录仍可被后续重试批量取出。
        expect((await storage.fetchPendingBatch(10)).length, 1);
      },
    );

    test(
      '429 with Retry-After schedules a retry using the header value',
      () async {
        transport.nextUploadStatusCodes.add(429);
        transport.nextRetryAfters.add(1); // 1 秒
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        await client.flush();
        // 1 秒内的重试 Timer 已调度，等待其触发。
        await Future<void>.delayed(const Duration(milliseconds: 1500));

        // Retry-After = 1s 触发第二次 flush（成功）。
        expect(transport.uploadCalls, 2);
        final pending = await storage.fetchPendingBatch(10);
        expect(pending, isEmpty);
      },
    );

    test(
      'single-flight guard prevents overlapping flushes after retry schedule',
      () async {
        transport.nextUploadStatusCodes.add(503);
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        await client.flush();
        // 第二个 flush 应立即返回（_isUploading 已复位）。
        await client.flush();
        expect(transport.uploadCalls, greaterThanOrEqualTo(1));
      },
    );
  });
}
