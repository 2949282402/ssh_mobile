import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_retry_test_support.dart';

void main() {
  group('TelemetryClient retry storage and replay boundaries', () {
    test('contains insert failures and returns false to callers', () async {
      final storage = ThrowingInsertTelemetryStorage();
      final client = buildRetryTelemetryClient(
        FakeTelemetryTimerFactory(),
        ScriptedTelemetryTransport(),
        storage: storage,
      );

      expect(
        await client.record(event: TelemetryEvents.sshSessionStarted),
        isFalse,
      );
      expect(storage.insertCalls, 1);
      expect(
        client.latestDiagnostics.lastSyncError,
        'Telemetry storage operation failed',
      );

      await client.dispose();
    });

    test(
      'rejects unsafe config metadata before inserting an envelope',
      () async {
        final storage = CloseTrackingTelemetryStorage();
        final client = buildRetryTelemetryClient(
          FakeTelemetryTimerFactory(),
          ScriptedTelemetryTransport(),
          storage: storage,
          config: const TelemetryClientConfig(
            baseUrl: 'https://telemetry.example.test',
            deviceId: 'device-safe',
            appVersion: 'token value',
            buildNumber: '100',
            platform: 'android',
            releaseChannel: 'test',
            telemetryEnabled: true,
            deviceEnrollmentSecret: 'test-secret',
            policyFetchIntervalSeconds: 0,
          ),
        );

        expect(
          await client.record(event: TelemetryEvents.sshSessionStarted),
          isFalse,
        );
        expect(storage.insertCalls, 0);

        await client.dispose();
      },
    );

    test(
      'gates a queued trigger behind the failed upload retry delay',
      () async {
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport(
          firstUploadGate: Completer<void>(),
          uploadOutcomes: [
            const TelemetryUploadException(
              'rate limited',
              statusCode: 429,
              retryAfterSeconds: 7,
            ),
            null,
          ],
        );
        final client = buildRetryTelemetryClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        final first = client.flush();
        await transport.firstUploadStarted.future;

        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'queued-after-failure'},
        );
        final queued = client.flush();
        expect(identical(first, queued), isTrue);

        transport.firstUploadGate!.complete();
        await timers.oneShotScheduled.future;

        expect(transport.uploadCalls, 1);
        expect(timers.oneShotTimers, hasLength(1));
        expect(
          timers.oneShotTimers.single.duration,
          const Duration(seconds: 7),
        );
        expect(timers.oneShotTimers.single.isActive, isTrue);

        await timers.oneShotTimers.single.fire();
        await Future.wait([first, queued]);

        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test(
      'partial ACKs sync acknowledged rows and retry unacknowledged rows',
      () async {
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport();
        final client = buildRetryTelemetryClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'partial-ack'},
        );
        final pending = await client.storage.fetchPendingBatch(10);
        transport.ackResultOutcomes.add([
          TelemetryAckResult(
            eventId: pending.first.eventId,
            status: 'accepted',
          ),
        ]);
        transport.ackResultOutcomes.add(null);

        await client.flush();

        expect(transport.uploadCalls, 1);
        expect(await client.storage.fetchPendingBatch(10), hasLength(1));
        expect(timers.oneShotTimers, hasLength(1));
        expect(timers.oneShotTimers.single.isActive, isTrue);

        await timers.oneShotTimers.single.fire();

        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test('empty ACK results remain pending and schedule a retry', () async {
      final timers = FakeTelemetryTimerFactory();
      final transport = ScriptedTelemetryTransport(
        ackResultOutcomes: [const <TelemetryAckResult>[], null],
      );
      final client = buildRetryTelemetryClient(timers, transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.uploadCalls, 1);
      expect(await client.storage.fetchPendingBatch(10), hasLength(1));
      expect(timers.oneShotTimers, hasLength(1));
      expect(timers.oneShotTimers.single.isActive, isTrue);

      await timers.oneShotTimers.single.fire();

      expect(transport.uploadCalls, 2);
      expect(await client.storage.fetchPendingBatch(10), isEmpty);

      await client.dispose();
    });

    test(
      'flush waits for replay cleanup and its queued follow-up drain',
      () async {
        final timers = FakeTelemetryTimerFactory();
        final transport = ScriptedTelemetryTransport(
          firstUploadGate: Completer<void>(),
          secondUploadGate: Completer<void>(),
        );
        final client = buildRetryTelemetryClient(timers, transport);

        await client.record(event: TelemetryEvents.sshSessionStarted);
        final replay = client.replayAllLocalRecords();
        await transport.firstUploadStarted.future;

        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'replay-follow-up'},
        );
        expect(transport.uploadCalls, 1);
        expect(await client.storage.fetchPendingBatch(10), hasLength(2));
        final flush = client.flush();
        var flushCompleted = false;
        unawaited(flush.then((_) => flushCompleted = true));
        var replayCompleted = false;
        unawaited(replay.then((_) => replayCompleted = true));

        transport.firstUploadGate!.complete();
        await transport.secondUploadStarted.future;
        await Future<void>.value();

        expect(flushCompleted, isFalse);
        expect(replayCompleted, isFalse);

        transport.secondUploadGate!.complete();
        await Future.wait([flush, replay]);
        expect(flushCompleted, isTrue);
        expect(replayCompleted, isTrue);
        expect(transport.uploadCalls, 2);
        expect(await client.storage.fetchPendingBatch(10), isEmpty);

        await client.dispose();
      },
    );

    test('stale policy 401 does not clear a newer upload token', () async {
      final timers = FakeTelemetryTimerFactory();
      final transport = StalePolicyTelemetryTransport();
      final client = buildRetryTelemetryClient(timers, transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();
      expect(transport.authCalls, 1);

      final policyRefresh = client.refreshPolicy();
      await transport.policyRequestStarted.future;

      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: const {'session_type': 'upload-reauth'},
      );
      await client.flush();
      expect(transport.authCalls, 2);

      transport.policyRequestGate.complete();
      expect(await policyRefresh, isFalse);

      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: const {'session_type': 'token-retained'},
      );
      await client.flush();

      expect(transport.authCalls, 2);
      expect(await client.storage.fetchPendingBatch(10), isEmpty);

      await client.dispose();
    });

    test('matching policy 401 clears the cached token', () async {
      final timers = FakeTelemetryTimerFactory();
      final transport = StalePolicyTelemetryTransport();
      final client = buildRetryTelemetryClient(timers, transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();
      expect(transport.authCalls, 1);

      final refresh = client.refreshPolicy();
      await transport.policyRequestStarted.future;
      transport.policyRequestGate.complete();
      expect(await refresh, isFalse);

      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: const {'session_type': 'after-policy-401'},
      );
      await client.flush();

      expect(transport.authCalls, 2);
      expect(await client.storage.fetchPendingBatch(10), isEmpty);
      await client.dispose();
    });

    test('retries a batch after reauthentication fails', () async {
      final timers = FakeTelemetryTimerFactory();
      final transport = ScriptedTelemetryTransport(
        uploadOutcomes: [
          const TelemetryUploadException('expired', statusCode: 401),
          const TelemetryUploadException('still unavailable', statusCode: 503),
        ],
      );
      final client = buildRetryTelemetryClient(timers, transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.uploadCalls, 2);
      expect(timers.oneShotTimers, hasLength(1));
      expect(await client.storage.fetchPendingBatch(10), hasLength(1));
      await client.dispose();
    });

    test('reauthenticates after a repeated 401 on the retry attempt', () async {
      final timers = FakeTelemetryTimerFactory();
      final transport = ScriptedTelemetryTransport(
        uploadOutcomes: [
          const TelemetryUploadException('expired', statusCode: 401),
          const TelemetryUploadException('still expired', statusCode: 401),
          null,
        ],
      );
      final client = buildRetryTelemetryClient(timers, transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.authCalls, 2);
      expect(transport.uploadCalls, 2);
      expect(timers.oneShotTimers.single.isActive, isTrue);

      await timers.oneShotTimers.single.fire();

      expect(transport.authCalls, 3);
      expect(transport.uploadCalls, 3);
      expect(await client.storage.fetchPendingBatch(10), isEmpty);
      await client.dispose();
    });

    test('clears the token when replay receives unauthorized', () async {
      final timers = FakeTelemetryTimerFactory();
      final transport = ScriptedTelemetryTransport(
        uploadOutcomes: [
          const TelemetryUploadException('unauthorized', statusCode: 401),
          const TelemetryUploadException(
            'reauthenticated token rejected',
            statusCode: 401,
          ),
        ],
      );
      final client = buildRetryTelemetryClient(timers, transport);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      expect(await client.replayAllLocalRecords(), 0);
      expect(transport.authCalls, 2);
      expect(transport.uploadCalls, 2);
      expect(await client.storage.fetchPendingBatch(10), hasLength(1));
      await client.dispose();
    });
  });
}
