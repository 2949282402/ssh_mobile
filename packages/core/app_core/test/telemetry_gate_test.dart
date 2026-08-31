import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_client_test_support.dart';

void main() {
  test('starts disabled and does not touch local event storage', () async {
    final storage = MemoryTelemetryStorage();
    final transport = TestTelemetryTransport();
    final client = TelemetryClient(
      config: const TelemetryClientConfig(
        baseUrl: 'https://telemetry.example.test',
        deviceId: 'device-gated',
        appVersion: '1.0.0',
        buildNumber: '1',
        platform: 'test',
        releaseChannel: 'test',
        policyFetchIntervalSeconds: 0,
      ),
      storage: storage,
      transport: transport,
    );
    addTearDown(client.dispose);

    expect(client.telemetryEnabled, isFalse);
    expect(client.recordingEnabled, isFalse);
    expect(
      await client.record(event: TelemetryEvents.sshSessionStarted),
      isFalse,
    );
    await client.flush();
    expect(await client.refreshPolicy(), isFalse);
    expect(transport.authCalls, 0);
    expect(await storage.fetchAllForReplay(), isEmpty);
    final diagnostics = await client.getDiagnostics();
    expect(diagnostics.telemetryEnabled, isFalse);
    expect(diagnostics.totalCount, 0);
  });

  test('enabling and disabling the gate controls event persistence', () async {
    final storage = MemoryTelemetryStorage();
    final client = buildTestTelemetryClient(
      storage: storage,
      transport: TestTelemetryTransport(),
    );
    addTearDown(client.dispose);

    expect(client.telemetryEnabled, isTrue);
    expect(
      await client.record(event: TelemetryEvents.sshSessionStarted),
      isTrue,
    );
    expect(await storage.fetchAllForReplay(), hasLength(1));

    await client.setTelemetryEnabled(false);
    expect(client.telemetryEnabled, isFalse);
    expect(client.recordingEnabled, isFalse);
    expect(
      await client.record(event: TelemetryEvents.sshSessionStarted),
      isFalse,
    );
    expect(await storage.fetchAllForReplay(), hasLength(1));

    await client.setTelemetryEnabled(true);
    expect(client.telemetryEnabled, isTrue);
    expect(
      await client.record(event: TelemetryEvents.sshSessionStarted),
      isTrue,
    );
    expect(await storage.fetchAllForReplay(), hasLength(2));
  });

  test(
    'disabled telemetry log sink does not enqueue or persist records',
    () async {
      final storage = MemoryTelemetryStorage();
      final client = TelemetryClient(
        config: const TelemetryClientConfig(
          baseUrl: 'https://telemetry.example.test',
          deviceId: 'device-log-gated',
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'test',
          releaseChannel: 'test',
          policyFetchIntervalSeconds: 0,
        ),
        storage: storage,
      );
      final sink = TelemetryLogSink(client: client);
      addTearDown(sink.close);
      addTearDown(client.dispose);

      sink.write(
        LogRecord(
          timestamp: DateTime.utc(2026, 8, 31),
          level: LogLevel.error,
          message: 'must not be cached',
          source: 'test',
          eventName: TelemetryEvents.appErrorCaptured.name,
        ),
      );

      await sink.pendingWrites;
      expect(await storage.fetchAllForReplay(), isEmpty);
    },
  );

  test(
    'a disabled upload policy keeps local recording but stops uploads',
    () async {
      final storage = MemoryTelemetryStorage();
      final client = buildTestTelemetryClient(
        storage: storage,
        transport: TestTelemetryTransport(),
        initialPolicy: const TelemetryUploadPolicy(
          uploadEnabled: false,
          batchSizeThreshold: 2,
          timeIntervalSeconds: 60,
          maxBatchSize: 10,
          clientMaxLocalRecords: 100,
          specialTriggers: [],
          policyVersion: 1,
        ),
      );
      addTearDown(client.dispose);

      await client.ready;
      expect(client.telemetryEnabled, isTrue);
      expect(client.recordingEnabled, isTrue);
      expect(
        await client.record(event: TelemetryEvents.sshSessionStarted),
        isTrue,
      );
      expect(await storage.fetchAllForReplay(), hasLength(1));
    },
  );
}
