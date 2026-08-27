import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TelemetryStorage & State Machine', () {
    late TelemetryStorage storage;

    setUp(() {
      storage = MemoryTelemetryStorage();
    });

    test(
      'newly inserted records start in pending state with null logicalDeletedAt',
      () async {
        final record = TelemetryEventRecord(
          eventId: 'evt-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: DateTime.now(),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        await storage.insertRecord(record);

        final pending = await storage.fetchPendingBatch(10);
        expect(pending.length, 1);
        expect(pending[0].eventId, 'evt-1');
        expect(pending[0].syncState, TelemetrySyncState.pending);
        expect(pending[0].logicalDeletedAt, isNull);
      },
    );

    test(
      'accepted and already_seen ACKs transition to synced with logicalDeletedAt atomically',
      () async {
        final r1 = TelemetryEventRecord(
          eventId: 'evt-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: DateTime.now(),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        final r2 = TelemetryEventRecord(
          eventId: 'evt-2',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: DateTime.now(),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        await storage.insertRecord(r1);
        await storage.insertRecord(r2);

        await storage.applyAckResults([
          const TelemetryAckResult(eventId: 'evt-1', status: 'accepted'),
          const TelemetryAckResult(eventId: 'evt-2', status: 'already_seen'),
        ]);

        final pending = await storage.fetchPendingBatch(10);
        expect(pending, isEmpty);

        final all = await storage.fetchAllForReplay();
        expect(all.length, 2);
        expect(all[0].syncState, TelemetrySyncState.synced);
        expect(all[0].logicalDeletedAt, isNotNull);
        expect(all[1].syncState, TelemetrySyncState.synced);
        expect(all[1].logicalDeletedAt, isNotNull);
      },
    );

    test(
      'rejected ACK transitions to rejected with null logicalDeletedAt and stops auto-retry',
      () async {
        final r1 = TelemetryEventRecord(
          eventId: 'evt-rej-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: DateTime.now(),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        await storage.insertRecord(r1);

        await storage.applyAckResults([
          const TelemetryAckResult(
            eventId: 'evt-rej-1',
            status: 'rejected',
            reason: 'Invalid schema',
          ),
        ]);

        // Rejected record is NOT in pending batch for auto-retry
        final pending = await storage.fetchPendingBatch(10);
        expect(pending, isEmpty);

        final all = await storage.fetchAllForReplay();
        expect(all.length, 1);
        expect(all[0].syncState, TelemetrySyncState.rejected);
        expect(all[0].logicalDeletedAt, isNull);

        final stats = await storage.getHealthStats(targetCapacity: 100);
        expect(stats.localRejectedCount, 1);
        expect(stats.localPendingCount, 0);
      },
    );

    test(
      'FIFO cleanup only deletes synced records and never deletes pending or rejected records',
      () async {
        // Insert 2 pending, 1 rejected, and 3 synced records
        final now = DateTime.now();

        final p1 = TelemetryEventRecord(
          eventId: 'p-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: now.subtract(const Duration(minutes: 50)),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        final p2 = TelemetryEventRecord(
          eventId: 'p-2',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: now.subtract(const Duration(minutes: 40)),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        final s1 = TelemetryEventRecord(
          eventId: 's-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: now.subtract(const Duration(minutes: 30)),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        final s2 = TelemetryEventRecord(
          eventId: 's-2',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: now.subtract(const Duration(minutes: 20)),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        final rej = TelemetryEventRecord(
          eventId: 'r-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: now.subtract(const Duration(minutes: 10)),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        await storage.insertRecord(p1);
        await storage.insertRecord(p2);
        await storage.insertRecord(s1);
        await storage.insertRecord(s2);
        await storage.insertRecord(rej);

        await storage.applyAckResults([
          const TelemetryAckResult(eventId: 's-1', status: 'accepted'),
          const TelemetryAckResult(eventId: 's-2', status: 'accepted'),
          const TelemetryAckResult(eventId: 'r-1', status: 'rejected'),
        ]);

        // Total 5 records (2 pending, 1 rejected, 2 synced).
        // Target capacity = 4.
        // FIFO purge should delete the oldest synced record (s-1) and leave 4 records (2 pending, 1 rejected, 1 synced).
        final purged = await storage.purgeOldSyncedRecords(targetCapacity: 4);
        expect(purged, 1);

        final remaining = await storage.fetchAllForReplay();
        final remainingIds = remaining.map((r) => r.eventId).toList();
        expect(remainingIds, containsAll(['p-1', 'p-2', 'r-1', 's-2']));
        expect(remainingIds, isNot(contains('s-1')));

        // Now set target capacity = 1.
        // There is only 1 synced record (s-2). Purging should delete s-2, leaving 3 records (p-1, p-2, r-1).
        // Pending and rejected records MUST NOT be deleted even though 3 > 1!
        final purged2 = await storage.purgeOldSyncedRecords(targetCapacity: 1);
        expect(purged2, 1);

        final remaining2 = await storage.fetchAllForReplay();
        final remainingIds2 = remaining2.map((r) => r.eventId).toList();
        expect(remainingIds2, ['p-1', 'p-2', 'r-1']);

        // Check health stats: cacheOverflow should be true because un-purged (3) > target (1)
        final stats = await storage.getHealthStats(targetCapacity: 1);
        expect(stats.localPendingCount, 2);
        expect(stats.localRejectedCount, 1);
        expect(stats.localSyncedCount, 0);
        expect(stats.cacheOverflow, isTrue);
      },
    );

    test('FileTelemetryStorage synchronously reports health stats and persists records', () async {
      final tempDir = await Directory.systemTemp.createTemp('telemetry_file_test_');
      final filePath = '${tempDir.path}/telemetry_events.jsonl';

      try {
        final fileStorage = FileTelemetryStorage(filePath: filePath);
        final r1 = TelemetryEventRecord(
          eventId: 'file-evt-1',
          recordType: TelemetryRecordType.analytics,
          eventName: 'ssh.session.started',
          eventVersion: 1,
          deviceId: 'dev-1',
          sessionId: 'sess-1',
          traceId: 'trace-1',
          occurredAt: DateTime.now().toUtc(),
          feature: 'ssh',
          severity: TelemetrySeverity.info,
          appVersion: '1.0.0',
          buildNumber: '100',
          platform: 'android',
        );

        await fileStorage.insertRecord(r1);

        // Synchronous health check before another instance does async load
        final healthSync = fileStorage.getHealthStatsSync(targetCapacity: 100);
        expect(healthSync.localPendingCount, 1);
        expect(healthSync.totalCount, 1);

        // Re-open storage on same file to test _ensureLoadedSync
        final fileStorage2 = FileTelemetryStorage(filePath: filePath);
        final healthSync2 = fileStorage2.getHealthStatsSync(targetCapacity: 100);
        expect(healthSync2.localPendingCount, 1);
        expect(healthSync2.totalCount, 1);

        final pending = await fileStorage2.fetchPendingBatch(10);
        expect(pending.length, 1);
        expect(pending[0].eventId, 'file-evt-1');

        await fileStorage.close();
        await fileStorage2.close();
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
