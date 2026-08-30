import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_client_test_support.dart';

TelemetryEventRecord _record(String id, DateTime occurredAt) {
  return TelemetryEventRecord(
    eventId: id,
    recordType: TelemetryRecordType.analytics,
    eventName: 'ssh.session.started',
    eventVersion: 1,
    deviceId: 'dev-client-1',
    sessionId: 'sess-fixed',
    traceId: 'trace-$id',
    occurredAt: occurredAt,
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    appVersion: '1.0.0',
    buildNumber: '100',
    platform: 'android',
    properties: const {'session_type': 'interactive'},
  );
}

TelemetryUploadPolicy _capacityPolicy(int target) {
  return TelemetryUploadPolicy(
    uploadEnabled: true,
    batchSizeThreshold: 50,
    timeIntervalSeconds: 60,
    maxBatchSize: 50,
    clientMaxLocalRecords: target,
    specialTriggers: const [],
    policyVersion: 1,
  );
}

final class _FailingPurgeStorage extends MemoryTelemetryStorage {
  int purgeCalls = 0;

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async {
    purgeCalls++;
    throw StateError('purge unavailable');
  }
}

final class _CountingPurgeStorage extends MemoryTelemetryStorage {
  int purgeCalls = 0;

  @override
  Future<int> purgeOldSyncedRecords({required int targetCapacity}) async {
    purgeCalls++;
    return super.purgeOldSyncedRecords(targetCapacity: targetCapacity);
  }
}

final class _DuplicateStorage extends MemoryTelemetryStorage {
  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    throw TelemetryStorageDuplicateException(record.eventId);
  }
}

void main() {
  test(
    'record triggers bounded capacity maintenance after durable insert',
    () async {
      final storage = MemoryTelemetryStorage();
      final oldest = DateTime.utc(2026, 8, 1);
      await storage.insertRecord(_record('old-1', oldest));
      await storage.insertRecord(
        _record('old-2', oldest.add(const Duration(minutes: 1))),
      );
      await storage.insertRecord(
        _record('old-3', oldest.add(const Duration(minutes: 2))),
      );
      await storage.applyAckResults([
        const TelemetryAckResult(eventId: 'old-1', status: 'accepted'),
        const TelemetryAckResult(eventId: 'old-2', status: 'accepted'),
        const TelemetryAckResult(eventId: 'old-3', status: 'accepted'),
      ]);

      final transport = TestTelemetryTransport();
      final client = buildTestTelemetryClient(
        storage: storage,
        transport: transport,
        initialPolicy: _capacityPolicy(2),
      );
      addTearDown(client.dispose);

      expect(
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'new'},
        ),
        isTrue,
      );

      final remaining = await storage.fetchAllForReplay();
      final ids = remaining.map((record) => record.eventId).toSet();
      expect(ids, containsAll(<String>{'old-3'}));
      expect(ids, isNot(contains('old-1')));
      expect(ids, isNot(contains('old-2')));
      expect(remaining, hasLength(2));
      expect(transport.uploadCalls, 0);
    },
  );

  test(
    'capacity maintenance failure does not make a durable record fail',
    () async {
      final storage = _FailingPurgeStorage();
      final client = buildTestTelemetryClient(
        storage: storage,
        transport: TestTelemetryTransport(),
        initialPolicy: _capacityPolicy(2),
      );
      addTearDown(client.dispose);

      expect(
        await client.record(
          event: TelemetryEvents.sshSessionStarted,
          properties: const {'session_type': 'maintenance-failure'},
        ),
        isTrue,
      );
      expect(storage.purgeCalls, 1);
      expect(await storage.fetchAllForReplay(), hasLength(1));
      expect(
        client.latestDiagnostics.lastSyncError,
        'Telemetry storage operation failed',
      );
    },
  );

  test('a duplicate eventId is surfaced as a failed record', () async {
    final storage = _DuplicateStorage();
    final client = buildTestTelemetryClient(
      storage: storage,
      transport: TestTelemetryTransport(),
    );
    addTearDown(client.dispose);

    expect(
      await client.record(
        event: TelemetryEvents.sshSessionStarted,
        properties: const {'session_type': 'duplicate'},
      ),
      isFalse,
    );
  });

  test(
    'capacity maintenance checks the first write and every 32 later writes',
    () async {
      final storage = _CountingPurgeStorage();
      final client = buildTestTelemetryClient(
        storage: storage,
        transport: TestTelemetryTransport(),
        initialPolicy: _capacityPolicy(1000),
      );
      addTearDown(client.dispose);

      Future<void> recordCadenceEvent(int index) async {
        expect(
          await client.record(
            event: TelemetryEvents.sshSessionStarted,
            properties: {'session_type': 'cadence-$index'},
          ),
          isTrue,
        );
      }

      await recordCadenceEvent(1);
      expect(storage.purgeCalls, 1);

      for (var index = 2; index <= 32; index++) {
        await recordCadenceEvent(index);
      }
      expect(storage.purgeCalls, 1);

      await recordCadenceEvent(33);
      expect(storage.purgeCalls, 2);
    },
  );

  test('health reports backlog ages and exact overflow count', () async {
    final storage = MemoryTelemetryStorage();
    final now = DateTime.now().toUtc();
    await storage.insertRecord(
      _record('pending-old', now.subtract(const Duration(hours: 2))),
    );
    await storage.insertRecord(
      _record('rejected-old', now.subtract(const Duration(hours: 3))),
    );
    await storage.applyAckResults([
      const TelemetryAckResult(eventId: 'rejected-old', status: 'rejected'),
    ]);

    final health = await storage.getHealthStats(targetCapacity: 1);

    expect(health.overflowCount, 1);
    expect(health.cacheOverflow, isTrue);
    expect(health.oldestPendingAge, isNotNull);
    expect(health.oldestRejectedAge, isNotNull);
    expect(health.oldestPendingAge!, greaterThan(const Duration(hours: 1)));
    expect(health.oldestRejectedAge!, greaterThan(const Duration(hours: 2)));
  });
}
