import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_client_test_support.dart';

TelemetryUploadPolicy policyWithVersion(
  int version, {
  int batchSizeThreshold = 2,
  bool uploadEnabled = true,
}) {
  return TelemetryUploadPolicy(
    uploadEnabled: uploadEnabled,
    batchSizeThreshold: batchSizeThreshold,
    timeIntervalSeconds: 60,
    maxBatchSize: 10,
    clientMaxLocalRecords: 100,
    specialTriggers: const [
      'highPriorityError',
      'appBackground',
      'networkRecovered',
      'appForegroundWithBacklog',
    ],
    policyVersion: version,
  );
}

void main() {
  group('TelemetryClient last-known-good policy', () {
    test('restores a newer policy after a client restart', () async {
      final storage = MemoryTelemetryStorage();
      final transport = TestTelemetryTransport()
        ..remotePolicy = policyWithVersion(2, batchSizeThreshold: 7);
      final first = buildTestTelemetryClient(
        storage: storage,
        transport: transport,
      );

      expect(await first.refreshPolicy(), isTrue);
      expect(first.activePolicy.policyVersion, 2);
      await first.dispose();

      final second = buildTestTelemetryClient(
        storage: storage,
        transport: TestTelemetryTransport(),
      );
      await second.ready;

      expect(second.activePolicy.policyVersion, 2);
      expect(second.activePolicy.batchSizeThreshold, 7);
      await second.dispose();
    });

    test(
      'does not downgrade a restored policy from a stale response',
      () async {
        final storage = MemoryTelemetryStorage();
        await storage.saveLastKnownGoodPolicy(policyWithVersion(4));
        final transport = TestTelemetryTransport()
          ..remotePolicy = policyWithVersion(3, batchSizeThreshold: 9);
        final client = buildTestTelemetryClient(
          storage: storage,
          transport: transport,
        );
        await client.ready;

        expect(client.activePolicy.policyVersion, 4);
        expect(await client.refreshPolicy(), isFalse);
        expect(client.activePolicy.policyVersion, 4);
        expect(client.activePolicy.batchSizeThreshold, 2);

        await client.dispose();
      },
    );

    test('rejects persisted policies outside the safety bounds', () async {
      final storage = MemoryTelemetryStorage();
      await storage.saveLastKnownGoodPolicy(
        policyWithVersion(5, batchSizeThreshold: 0),
      );
      final client = buildTestTelemetryClient(
        storage: storage,
        transport: TestTelemetryTransport(),
      );

      await client.ready;

      expect(client.activePolicy.policyVersion, 1);
      expect(client.activePolicy.batchSizeThreshold, 2);
      await client.dispose();
    });

    test(
      'does not upload work queued before a restored disabled policy is ready',
      () async {
        final storage = _BlockingPolicyStorage(
          policy: policyWithVersion(2, uploadEnabled: false),
        );
        final transport = TestTelemetryTransport();
        final client = TelemetryClient(
          config: const TelemetryClientConfig(
            baseUrl: 'https://telemetry.example.test',
            deviceId: 'device-policy-disabled',
            appVersion: '1.0.0',
            buildNumber: '1',
            platform: 'android',
            releaseChannel: 'test',
            deviceEnrollmentSecret: 'test-secret',
            policyFetchIntervalSeconds: 0,
          ),
          storage: storage,
          transport: transport,
          initialPolicy: policyWithVersion(1),
        );

        await storage.loadStarted.future;
        final record = client.record(event: TelemetryEvents.sshSessionStarted);
        final flush = client.flush();
        storage.release.complete();

        expect(await record, isTrue);
        await flush;
        await client.ready;

        expect(client.activePolicy.uploadEnabled, isFalse);
        expect(transport.authCalls, 0);
        expect(transport.uploadCalls, 0);
        expect(await storage.fetchPendingBatch(10), hasLength(1));

        await client.dispose();
      },
    );

    test('replay waits for restored policy before authenticating', () async {
      final storage = _BlockingPolicyStorage(
        policy: policyWithVersion(2, uploadEnabled: false),
      );
      final transport = TestTelemetryTransport();
      final client = TelemetryClient(
        config: const TelemetryClientConfig(
          baseUrl: 'https://telemetry.example.test',
          deviceId: 'device-policy-replay',
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'android',
          releaseChannel: 'test',
          deviceEnrollmentSecret: 'test-secret',
          policyFetchIntervalSeconds: 0,
        ),
        storage: storage,
        transport: transport,
        initialPolicy: policyWithVersion(1),
      );

      await storage.insertRecord(
        TelemetryEventRecord(
          eventId: 'policy-replay',
          recordType: TelemetryRecordType.analytics,
          eventName: TelemetryEvents.sshSessionStarted.name,
          eventVersion: TelemetryEvents.sshSessionStarted.version,
          deviceId: 'device-policy-replay',
          sessionId: 'session-policy-replay',
          traceId: 'trace-policy-replay',
          occurredAt: DateTime.utc(2026, 8, 28),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'android',
          releaseChannel: 'test',
          properties: const <String, dynamic>{},
        ),
      );

      await storage.loadStarted.future;
      final replay = client.replayAllLocalRecords();
      await Future<void>.delayed(Duration.zero);
      expect(transport.authCalls, 0);

      storage.release.complete();
      expect(await replay, 0);
      expect(transport.authCalls, 0);
      expect(transport.uploadCalls, 0);

      await client.dispose();
    });

    test(
      'retains records written while policy restoration is pending',
      () async {
        final storage = _BlockingPolicyStorage();
        final client = TelemetryClient(
          config: const TelemetryClientConfig(
            baseUrl: 'https://telemetry.example.test',
            deviceId: 'device-policy-order',
            appVersion: '1.0.0',
            buildNumber: '1',
            platform: 'android',
            releaseChannel: 'test',
            deviceEnrollmentSecret: 'test-secret',
            policyFetchIntervalSeconds: 0,
          ),
          storage: storage,
          transport: TestTelemetryTransport(),
          initialPolicy: policyWithVersion(1),
        );

        await storage.loadStarted.future;
        final record = client.record(event: TelemetryEvents.sshSessionStarted);
        storage.release.complete();

        expect(await record, isTrue);
        await client.ready;
        expect(await storage.fetchAllForReplay(), hasLength(1));
        await client.dispose();
      },
    );
  });
}

final class _BlockingPolicyStorage extends MemoryTelemetryStorage {
  _BlockingPolicyStorage({this.policy});

  final TelemetryUploadPolicy? policy;
  final Completer<void> loadStarted = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<TelemetryUploadPolicy?> loadLastKnownGoodPolicy() async {
    if (!loadStarted.isCompleted) loadStarted.complete();
    await release.future;
    return policy ?? super.loadLastKnownGoodPolicy();
  }
}
