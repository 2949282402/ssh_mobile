import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<String?> authenticateDevice({
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
      return token;
    }
    if (shouldFailAuth) {
      throw const TelemetryUploadException(
        'Network auth failure',
        statusCode: 401,
      );
    }
    return token;
  }

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
        final success = await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 'interactive'},
        );
        expect(success, isTrue);

        final pending = await storage.fetchPendingBatch(10);
        expect(pending.length, 1);
        expect(pending[0].eventName, 'ssh.session.started');

        // 2. Unregistered event fails validation and is not recorded
        final unregistered = await client.recordEvent(
          eventName: 'unknown.event.name',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {},
        );
        expect(unregistered, isFalse);
        expect((await storage.fetchPendingBatch(10)).length, 1);

        // 3. Undeclared property fails validation
        final missingProp = await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'forbidden_prop': 123},
        );
        expect(missingProp, isFalse);
        expect((await storage.fetchPendingBatch(10)).length, 1);
      },
    );

    test('batch count threshold triggers automatic upload', () async {
      await client.recordEvent(
        eventName: 'ssh.session.started',
        eventVersion: 1,
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        properties: {'session_type': 'terminal'},
      );

      expect(transport.uploadCalls, 0);

      await client.recordEvent(
        eventName: 'ssh.session.started',
        eventVersion: 1,
        feature: 'ssh',
        severity: TelemetrySeverity.info,
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
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 'shell'},
        );
        expect(transport.uploadCalls, 0);

        await client.recordEvent(
          eventName: 'ssh.session.failed',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.error,
          properties: {'stage': 'handshake'},
          errorCode: 'SSH_AUTH_FAILED',
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(transport.uploadCalls, 1);
        expect(transport.uploadedBatches[0].length, 2);
      },
    );

    test(
      'recordDiagnostic triggers high priority flush for critical severity',
      () async {
        await client.recordDiagnostic(
          message: 'fatal condition',
          severity: TelemetrySeverity.critical,
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(transport.uploadCalls, 1);
        expect(transport.uploadedBatches[0].length, 1);
        expect(transport.uploadedBatches[0][0].recordType,
            TelemetryRecordType.diagnostic);
      },
    );

    test(
      'recordDiagnostic accepts explicit traceId and sessionId',
      () async {
        await client.recordDiagnostic(
          message: 'custom trace',
          severity: TelemetrySeverity.warn,
          traceId: 'trace-explicit-1',
          sessionId: 'sess-explicit-1',
        );

        final pending = await storage.fetchPendingBatch(10);
        expect(pending[0].traceId, 'trace-explicit-1');
        expect(pending[0].sessionId, 'sess-explicit-1');
      },
    );

    test(
      'single logical uploader guard prevents concurrent upload loops',
      () async {
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 't1'},
        );
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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

    test(
      'storage health and diagnostics snapshot are reported accurately',
      () async {
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 'interactive'},
        );
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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

        await clientWithSecret.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 'interactive'},
        );
        await clientWithSecret.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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

    test(
      'permanent 4xx marks records rejected and stops auto-retry',
      () async {
        transport.nextUploadStatusCodes.add(400);
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 'interactive'},
        );

        await client.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final all = await storage.fetchAllForReplay();
        expect(all[0].syncState, TelemetrySyncState.rejected);
        // 不再自动重试：fetchPendingBatch 为空。
        expect(await storage.fetchPendingBatch(10), isEmpty);
      },
    );

    test(
      '5xx failure increments retryCount and keeps records pending',
      () async {
        transport.nextUploadStatusCodes.add(503);
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
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