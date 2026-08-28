import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_client_test_support.dart';

void main() {
  group('TelemetryClient upload, replay, and authentication', () {
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

    test('remote policy fetch updates the active policy', () async {
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
      'replayAllLocalRecords sends all local records with original IDs',
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
        expect(transport.uploadedBatches, hasLength(2));
      },
    );

    test('replay revalidates persisted rows before sending them', () async {
      final persistedStorage = TestTelemetryStorage([
        persistedDiagnosticRecord(
          eventId: 'evt-replay-persisted',
          message: 'Cookie: session=persisted-cookie-value',
        ),
      ]);
      final persistedClient = buildTestTelemetryClient(
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

    test('sessionId is stable while traceId changes per call', () async {
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
      expect(pending[0].sessionId, 'sess-fixed');
      expect(pending[0].traceId, isNot(pending[1].traceId));
      expect(pending[0].traceId.length, 36);
    });

    test(
      'auth proof includes an expiration epoch with an enrollment secret',
      () async {
        final clientWithSecret = buildTestTelemetryClient(
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
        expect(transport.authExpEpochs.first, isNotNull);
        await clientWithSecret.dispose();
      },
    );

    test(
      '401 clears token, re-authenticates once, and retries the same batch',
      () async {
        transport.authRepeatedAfter401 = true;
        transport.nextUploadStatusCodes.add(401);
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        final diagBefore = await client.getDiagnostics();
        expect(diagBefore.localPendingCount, 1);

        await client.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(transport.authCalls, 2);
        expect(transport.uploadCalls, 2);
        expect(await storage.fetchPendingBatch(10), isEmpty);
        expect(
          (await storage.fetchAllForReplay())[0].syncState,
          TelemetrySyncState.synced,
        );
      },
    );

    test('auth failure keeps records pending without deleting them', () async {
      transport.shouldFailAuth = true;
      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: {'session_type': 'interactive'},
      );

      await client.flush();

      expect(await storage.fetchPendingBatch(10), hasLength(1));
      final all = await storage.fetchAllForReplay();
      expect(all[0].syncState, TelemetrySyncState.pending);
      expect(all[0].logicalDeletedAt, isNull);
    });

    test('invalid auth responses keep records pending', () async {
      transport.authResultOverride = const TelemetryAuthResult(
        token: '',
        expiresInSeconds: 0,
      );
      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: {'session_type': 'invalid-auth-response'},
      );

      await client.flush();

      expect(transport.authCalls, 1);
      expect(await storage.fetchPendingBatch(10), hasLength(1));
      expect(
        client.latestDiagnostics.lastSyncError,
        'Device authentication failed',
      );
    });

    test(
      'maps code-only upload failures without exposing their message',
      () async {
        transport.uploadFailure = const TelemetryUploadException(
          'contains an untrusted detail',
          errorCode: 'UPSTREAM_DOWN',
        );
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'code-only-failure'},
        );

        await client.flush();

        expect(
          client.latestDiagnostics.lastSyncError,
          'Telemetry request failed (UPSTREAM_DOWN)',
        );
        expect(await storage.fetchPendingBatch(10), hasLength(1));
      },
    );

    test(
      'maps non-telemetry upload failures to a safe connection message',
      () async {
        transport.uploadFailure = const HttpException('socket detail');
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'http-failure'},
        );

        await client.flush();

        expect(
          client.latestDiagnostics.lastSyncError,
          'Telemetry request failed',
        );
        expect(await storage.fetchPendingBatch(10), hasLength(1));
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

      expect(
        (await storage.fetchAllForReplay())[0].syncState,
        TelemetrySyncState.rejected,
      );
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
        expect(await storage.fetchPendingBatch(10), hasLength(1));
      },
    );

    test(
      '429 with Retry-After schedules a retry using the header value',
      () async {
        transport.nextUploadStatusCodes.add(429);
        transport.nextRetryAfters.add(1);
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: {'session_type': 'interactive'},
        );

        await client.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1500));

        expect(transport.uploadCalls, 2);
        expect(await storage.fetchPendingBatch(10), isEmpty);
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
        await client.flush();
        expect(transport.uploadCalls, greaterThanOrEqualTo(1));
      },
    );
  });
}
