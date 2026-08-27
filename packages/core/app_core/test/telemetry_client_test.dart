import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

class MockTelemetryTransport implements TelemetryTransport {
  String token = 'mock-test-token-123';
  TelemetryUploadPolicy? remotePolicy;
  final List<List<TelemetryEventRecord>> uploadedBatches = [];
  final List<TelemetryAckResult> nextAckResults = [];
  bool shouldFailAuth = false;
  bool shouldFailUpload = false;
  bool shouldFailPolicy = false;
  int authCalls = 0;
  int uploadCalls = 0;
  int policyCalls = 0;

  @override
  Future<String?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
  }) async {
    authCalls++;
    if (shouldFailAuth) {
      throw Exception('Network auth failure');
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
      throw Exception('Network policy fetch failure');
    }
    return remotePolicy ?? TelemetryUploadPolicy.defaultPolicy();
  }

  @override
  Future<List<TelemetryAckResult>> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    uploadCalls++;
    if (shouldFailUpload) {
      throw Exception('Network upload failure');
    }
    uploadedBatches.add(List.from(records));
    if (nextAckResults.isNotEmpty) {
      final results = List<TelemetryAckResult>.from(nextAckResults);
      nextAckResults.clear();
      return results;
    }
    return records
        .map((r) => TelemetryAckResult(eventId: r.eventId, status: 'accepted'))
        .toList();
  }
}

void main() {
  group('TelemetryClient & Dispatcher', () {
    late TelemetryStorage storage;
    late TelemetryCatalog catalog;
    late MockTelemetryTransport transport;
    late TelemetryClient client;

    setUp(() {
      storage = MemoryTelemetryStorage();
      catalog = TelemetryCatalog();
      transport = MockTelemetryTransport();

      client = TelemetryClient(
        config: const TelemetryClientConfig(
          baseUrl: 'http://127.0.0.1:8080',
          deviceId: 'dev-client-1',
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
          releaseChannel: 'beta',
        ),
        storage: storage,
        catalog: catalog,
        transport: transport,
        initialPolicy: const TelemetryUploadPolicy(
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
    });

    tearDown(() async {
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

      // Second record reaches batchSizeThreshold = 2, triggering flush
      await client.recordEvent(
        eventName: 'ssh.session.started',
        eventVersion: 1,
        feature: 'ssh',
        severity: TelemetrySeverity.info,
        properties: {'auth_method': 'password'},
      );

      // Allow microtask/async flush to complete
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(transport.uploadCalls, 1);
      expect(transport.uploadedBatches.length, 1);
      expect(transport.uploadedBatches[0].length, 2);

      // Verify records are marked as synced
      final pending = await storage.fetchPendingBatch(10);
      expect(pending, isEmpty);
    });

    test(
      'highPriorityError trigger immediately flushes even if batch size not reached',
      () async {
        // Record 1 info event
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 'shell'},
        );
        expect(transport.uploadCalls, 0);

        // Record 1 error event with highPriorityError trigger enabled
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
      'single logical uploader guard prevents concurrent upload loops',
      () async {
        await client.recordEvent(
          eventName: 'ssh.session.started',
          eventVersion: 1,
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          properties: {'session_type': 'interactive'},
        );

        // Run multiple simultaneous flush calls
        final f1 = client.flush();
        final f2 = client.flush();
        final f3 = client.flush();

        await Future.wait([f1, f2, f3]);

        // Only 1 upload network call should have occurred
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
        // Record 2 events
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

        // Replay all local records
        final replayedCount = await client.replayAllLocalRecords();
        expect(replayedCount, 2);
        expect(transport.uploadCalls, 2);
        expect(transport.uploadedBatches.length, 2);
        // Verify same event IDs preserved
        expect(
          transport.uploadedBatches[1].map((r) => r.eventId),
          transport.uploadedBatches[0].map((r) => r.eventId),
        );
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
  });
}
