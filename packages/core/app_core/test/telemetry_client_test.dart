import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_client_test_support.dart';

void main() {
  group('TelemetryClient recording and storage boundaries', () {
    late TelemetryStorage storage;
    late TestTelemetryTransport transport;
    late TelemetryClient client;

    setUp(() {
      storage = MemoryTelemetryStorage();
      transport = TestTelemetryTransport();
      client = buildTestTelemetryClient(storage: storage, transport: transport);
    });

    tearDown(() async {
      await client.dispose();
    });

    test(
      'validates event against catalog before inserting into storage',
      () async {
        final success = await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );
        expect(success, isTrue);

        final pending = await storage.fetchPendingBatch(10);
        expect(pending.length, 1);
        expect(pending[0].eventName, TelemetryEvents.sshSessionStarted.name);

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

        final forbiddenProperty = await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'forbidden_prop': 123},
        );
        expect(forbiddenProperty, isFalse);
        expect((await storage.fetchPendingBatch(10)).length, 1);
      },
    );

    test('revalidates and re-sanitizes persisted rows before upload', () async {
      final persistedStorage = TestTelemetryStorage([
        persistedDiagnosticRecord(
          eventId: 'evt-persisted-safe',
          message: 'Authorization: Bearer persisted-token-value',
        ),
        persistedDiagnosticRecord(
          eventId: 'evt-persisted-invalid',
          message: 'must not be uploaded',
          eventName: 'unknown.persisted.event',
        ),
      ]);
      final persistedClient = buildTestTelemetryClient(
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
        final persistedStorage = TestTelemetryStorage([
          persistedDiagnosticRecord(
            eventId: 'evt-persisted-invalid-only',
            message: 'must not be uploaded',
            eventName: 'unknown.persisted.event',
          ),
        ]);
        final persistedClient = buildTestTelemetryClient(
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
      final failingStorage = TestTelemetryStorage()..failFetchPending = true;
      final failingClient = buildTestTelemetryClient(
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

    test('contains storage failures while applying upload results', () async {
      final failingStorage = TestTelemetryStorage([
        persistedDiagnosticRecord(
          eventId: 'evt-persisted-ack-failure',
          message: 'ack write fails',
        ),
      ])..failApplyAck = true;
      final failingClient = buildTestTelemetryClient(
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
    });

    test('contains retry bookkeeping storage failures', () async {
      final failingStorage = TestTelemetryStorage([
        persistedDiagnosticRecord(
          eventId: 'evt-persisted-retry-failure',
          message: 'retry bookkeeping fails',
        ),
      ])..failRetryCount = true;
      transport.nextUploadStatusCodes.add(503);
      final failingClient = buildTestTelemetryClient(
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
    });

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
      'record derives envelope and error metadata from definitions',
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

    test('accepts generated SFTP failure metadata and mapped errors', () async {
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
    });

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
        expect(await client.record(event: unknownEvent), isFalse);
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
      expect(transport.uploadedBatches, hasLength(1));
      expect(transport.uploadedBatches[0], hasLength(2));
      expect(await storage.fetchPendingBatch(10), isEmpty);
    });

    test('high priority errors trigger an immediate flush', () async {
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
      expect(transport.uploadedBatches[0], hasLength(2));
    });

    test('typed critical records trigger a high priority flush', () async {
      await client.record(
        event: TelemetryEvents.appCrashReported,
        properties: {'message': 'fatal condition', 'category': 'crash'},
        errorCode: TelemetryErrorCodes.appFatalError,
        errorMessage: 'fatal condition',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(transport.uploadCalls, 1);
      expect(transport.uploadedBatches[0], hasLength(1));
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
  });

  test(
    'uses the safe default policy when no initial policy is supplied',
    () async {
      final storage = MemoryTelemetryStorage();
      final client = TelemetryClient(
        config: const TelemetryClientConfig(
          baseUrl: 'https://telemetry.example.test',
          deviceId: 'device-default-policy',
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'linux',
          releaseChannel: 'test',
          deviceEnrollmentSecret: 'default-policy-secret',
          policyFetchIntervalSeconds: 0,
        ),
        storage: storage,
        transport: TestTelemetryTransport(),
      );

      expect(client.activePolicy.uploadEnabled, isTrue);
      expect(client.activePolicy.maxBatchSize, 100);
      await client.dispose();
    },
  );

  test('classifies and formats telemetry upload exceptions', () {
    const rateLimited = TelemetryUploadException(
      'rate limited',
      statusCode: 429,
      retryAfterSeconds: 7,
      errorCode: 'RATE_LIMITED',
    );
    expect(rateLimited.isRateLimited, isTrue);
    expect(rateLimited.isServerError, isFalse);
    expect(rateLimited.toString(), contains('RATE_LIMITED'));

    const serverFailure = TelemetryUploadException(
      'unavailable',
      statusCode: 503,
    );
    expect(serverFailure.isServerError, isTrue);
    expect(const TelemetryUploadException('network').isServerError, isTrue);
  });

  test('contains storage failure while quarantining persisted rows', () async {
    final storage = TestTelemetryStorage([
      persistedDiagnosticRecord(
        eventId: 'evt-quarantine-storage-failure',
        message: 'invalid row',
        eventName: 'unknown.persisted.event',
      ),
    ])..failApplyAck = true;
    final client = buildTestTelemetryClient(
      storage: storage,
      transport: TestTelemetryTransport(),
    );

    await expectLater(client.flush(), completes);
    expect(
      client.latestDiagnostics.lastSyncError,
      'Telemetry storage operation failed',
    );
    expect(storage.records.single.syncState, TelemetrySyncState.pending);
    await client.dispose();
  });

  test(
    'contains storage failure while rejecting a permanent upload error',
    () async {
      final storage = TestTelemetryStorage([
        persistedDiagnosticRecord(
          eventId: 'evt-permanent-ack-storage-failure',
          message: 'permanent failure',
        ),
      ])..failApplyAck = true;
      final transport = TestTelemetryTransport()
        ..nextUploadStatusCodes.add(400);
      final client = buildTestTelemetryClient(
        storage: storage,
        transport: transport,
      );

      await expectLater(client.flush(), completes);
      expect(transport.uploadCalls, 1);
      expect(
        client.latestDiagnostics.lastSyncError,
        'Telemetry storage operation failed',
      );
      await client.dispose();
    },
  );
}
