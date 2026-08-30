// DriftTelemetryStorage 的 SQLite 持久化与状态机测试。

import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/drift_telemetry_storage.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_database.dart';

/// 构造一条测试记录。
TelemetryEventRecord record(
  String id, {
  DateTime? occurredAt,
  String? releaseChannel,
}) {
  return TelemetryEventRecord(
    eventId: id,
    recordType: TelemetryRecordType.analytics,
    eventName: 'ssh.session.started',
    eventVersion: 1,
    deviceId: 'dev-1',
    sessionId: 'sess-1',
    traceId: 'trace-$id',
    occurredAt: occurredAt ?? DateTime.now().toUtc(),
    feature: 'ssh',
    severity: TelemetrySeverity.info,
    appVersion: '1.0.0',
    buildNumber: '1',
    platform: 'linux',
    releaseChannel: releaseChannel,
    properties: {'session_type': 'interactive'},
  );
}

void main() {
  group('DriftTelemetryStorage', () {
    late DriftTelemetryStorage storage;
    late TelemetryDatabase database;

    setUp(() {
      database = TelemetryDatabase(executor: NativeDatabase.memory());
      storage = DriftTelemetryStorage(database: database);
    });

    tearDown(() async {
      await storage.close();
    });

    test('inserts records and fetches pending batch oldest-first', () async {
      await storage.insertRecord(
        record('e1', occurredAt: DateTime.utc(2026, 8, 1)),
      );
      await storage.insertRecord(
        record('e2', occurredAt: DateTime.utc(2026, 8, 2)),
      );

      final pending = await storage.fetchPendingBatch(10);
      expect(pending.length, 2);
      expect(pending[0].eventId, 'e1');
      expect(pending[1].eventId, 'e2');
      expect(pending[0].syncState, TelemetrySyncState.pending);
      expect(pending[0].retryCount, 0);
    });

    test('persists an optional release channel', () async {
      await storage.insertRecord(
        record('release-beta', releaseChannel: 'beta'),
      );

      final fetched = (await storage.fetchPendingBatch(10)).single;
      expect(fetched.releaseChannel, 'beta');
    });

    test('persists and restores the last-known-good policy', () async {
      const policy = TelemetryUploadPolicy(
        uploadEnabled: true,
        batchSizeThreshold: 7,
        timeIntervalSeconds: 60,
        maxBatchSize: 25,
        clientMaxLocalRecords: 100,
        specialTriggers: [
          'highPriorityError',
          'appBackground',
          'networkRecovered',
          'appForegroundWithBacklog',
        ],
        policyVersion: 3,
      );

      await storage.saveLastKnownGoodPolicy(policy);

      final restored = await storage.loadLastKnownGoodPolicy();
      expect(restored, isNotNull);
      expect(restored!.policyVersion, 3);
      expect(restored.batchSizeThreshold, 7);
      expect(restored.maxBatchSize, 25);
    });

    test(
      'rejects invalid policy writes instead of clamping durable state',
      () async {
        const invalid = TelemetryUploadPolicy(
          uploadEnabled: true,
          batchSizeThreshold: 7,
          timeIntervalSeconds: 60,
          maxBatchSize: 25,
          clientMaxLocalRecords: 100,
          specialTriggers: ['unsupportedTrigger'],
          policyVersion: 3,
        );

        await expectLater(
          storage.saveLastKnownGoodPolicy(invalid),
          throwsArgumentError,
        );
        expect(await storage.loadLastKnownGoodPolicy(), isNull);
      },
    );

    test(
      'ignores a policy row whose denormalized version does not match',
      () async {
        const policy = TelemetryUploadPolicy(
          uploadEnabled: true,
          batchSizeThreshold: 7,
          timeIntervalSeconds: 60,
          maxBatchSize: 25,
          clientMaxLocalRecords: 100,
          specialTriggers: ['networkRecovered'],
          policyVersion: 3,
        );
        await database
            .into(database.telemetryPolicyStates)
            .insert(
              TelemetryPolicyStatesCompanion.insert(
                id: const Value(1),
                policyJson: jsonEncode(policy.toJson()),
                policyVersion: 99,
                updatedAt: DateTime.utc(2026, 8, 28),
              ),
            );

        expect(await storage.loadLastKnownGoodPolicy(), isNull);
      },
    );

    test('rejects durable policy values outside the safety envelope', () async {
      await database
          .into(database.telemetryPolicyStates)
          .insert(
            TelemetryPolicyStatesCompanion.insert(
              id: const Value(1),
              policyJson: jsonEncode({
                'uploadEnabled': true,
                'batchSizeThreshold': 0,
                'timeIntervalSeconds': 60,
                'maxBatchSize': 25,
                'clientMaxLocalRecords': 100,
                'specialTriggers': ['networkRecovered'],
                'policyVersion': 3,
              }),
              policyVersion: 3,
              updatedAt: DateTime.utc(2026, 8, 28),
            ),
          );

      expect(await storage.loadLastKnownGoodPolicy(), isNull);
    });

    test(
      'eventId duplicate is surfaced without mutating the original',
      () async {
        await storage.insertRecord(record('dup-1'));
        await expectLater(
          storage.insertRecord(
            record(
              'dup-1',
            ).copyWith(properties: const {'session_type': 'replacement'}),
          ),
          throwsA(
            isA<TelemetryStorageDuplicateException>().having(
              (error) => error.eventId,
              'eventId',
              'dup-1',
            ),
          ),
        );
        final all = await storage.fetchAllForReplay();
        expect(all.length, 1);
        expect(all.single.properties['session_type'], 'interactive');
      },
    );

    test(
      'applyAckResults marks accepted as synced with logicalDeletedAt and resets retryCount',
      () async {
        await storage.insertRecord(record('ack-1'));

        final pending = await storage.fetchPendingBatch(10);
        expect(pending.length, 1);
        await storage.applyRetryCount(['ack-1'], increment: 3);

        await storage.applyAckResults([
          const TelemetryAckResult(eventId: 'ack-1', status: 'accepted'),
        ]);

        final all = await storage.fetchAllForReplay();
        expect(all[0].syncState, TelemetrySyncState.synced);
        expect(all[0].logicalDeletedAt, isNotNull);
        expect(all[0].retryCount, 0);

        // 不再进入 pending 批次。
        expect(await storage.fetchPendingBatch(10), isEmpty);
      },
    );

    test('applyRetryCount honors the requested increment', () async {
      await storage.insertRecord(record('retry-increment'));

      await storage.applyRetryCount(['retry-increment'], increment: 3);

      final persisted = (await storage.fetchAllForReplay()).single;
      expect(persisted.retryCount, 3);
    });

    test('partial ACK only transitions matching records', () async {
      await storage.insertRecord(record('ack-a'));
      await storage.insertRecord(record('ack-b'));

      await storage.applyAckResults([
        const TelemetryAckResult(eventId: 'ack-a', status: 'accepted'),
      ]);

      final all = await storage.fetchAllForReplay();
      final byId = {for (final r in all) r.eventId: r};
      expect(byId['ack-a']!.syncState, TelemetrySyncState.synced);
      expect(byId['ack-b']!.syncState, TelemetrySyncState.pending);
    });

    test('rejected ACK marks rejected and never auto-retries', () async {
      await storage.insertRecord(record('rej-1'));

      await storage.applyAckResults([
        const TelemetryAckResult(
          eventId: 'rej-1',
          status: 'rejected',
          reason: 'Invalid schema',
        ),
      ]);

      final all = await storage.fetchAllForReplay();
      expect(all[0].syncState, TelemetrySyncState.rejected);
      expect(all[0].logicalDeletedAt, isNull);
      expect(await storage.fetchPendingBatch(10), isEmpty);
    });

    test('FIFO purge deletes only synced records oldest-first', () async {
      final now = DateTime.utc(2026, 8, 10, 12, 0, 0);
      // 2 pending + 2 synced + 1 rejected
      await storage.insertRecord(
        record('p-1', occurredAt: now.subtract(Duration(minutes: 60))),
      );
      await storage.insertRecord(
        record('p-2', occurredAt: now.subtract(Duration(minutes: 50))),
      );
      await storage.insertRecord(
        record('s-1', occurredAt: now.subtract(Duration(minutes: 40))),
      );
      await storage.insertRecord(
        record('s-2', occurredAt: now.subtract(Duration(minutes: 30))),
      );
      await storage.insertRecord(
        record('r-1', occurredAt: now.subtract(Duration(minutes: 20))),
      );

      // 让 s-1/s-2 变为 synced，r-1 变为 rejected
      await storage.applyAckResults([
        const TelemetryAckResult(eventId: 's-1', status: 'accepted'),
        const TelemetryAckResult(eventId: 's-2', status: 'accepted'),
        const TelemetryAckResult(eventId: 'r-1', status: 'rejected'),
      ]);

      // 总数 5，容量 4 -> 删除最旧的 1 条 synced（s-1）
      final purged = await storage.purgeOldSyncedRecords(targetCapacity: 4);
      expect(purged, 1);

      final remaining = await storage.fetchAllForReplay();
      final ids = remaining.map((r) => r.eventId).toList();
      expect(ids, containsAll(['p-1', 'p-2', 'r-1', 's-2']));
      expect(ids, isNot(contains('s-1')));

      // 容量 1 -> 再删 1 条 synced（s-2），剩余 p-1/p-2/r-1 保留。
      final purged2 = await storage.purgeOldSyncedRecords(targetCapacity: 1);
      expect(purged2, 1);
      final remaining2 = await storage.fetchAllForReplay();
      final ids2 = remaining2.map((r) => r.eventId).toList();
      expect(ids2, ['p-1', 'p-2', 'r-1']);

      final stats = await storage.getHealthStats(targetCapacity: 1);
      expect(stats.localPendingCount, 2);
      expect(stats.localRejectedCount, 1);
      expect(stats.localSyncedCount, 0);
      expect(stats.cacheOverflow, isTrue);
      expect(stats.overflowCount, 2);
    });

    test(
      'purge with no purgeable synced deletes 0 and reports overflow',
      () async {
        await storage.insertRecord(record('pending-only'));
        final purged = await storage.purgeOldSyncedRecords(targetCapacity: 0);
        expect(purged, 0);

        final stats = await storage.getHealthStats(targetCapacity: 0);
        expect(stats.localPendingCount, 1);
        expect(stats.cacheOverflow, isTrue);
      },
    );

    test('pending and rejected records are NEVER deleted by purge', () async {
      // 全部是 pending/rejected，容量 1。
      await storage.insertRecord(record('pend-a'));
      await storage.insertRecord(record('pend-b'));
      await storage.insertRecord(record('rej-a'));
      await storage.applyAckResults([
        const TelemetryAckResult(eventId: 'rej-a', status: 'rejected'),
      ]);

      final purged = await storage.purgeOldSyncedRecords(targetCapacity: 1);
      expect(purged, 0);

      final remaining = await storage.fetchAllForReplay();
      expect(remaining.length, 3);
    });

    test('clearAll removes everything', () async {
      await storage.insertRecord(record('x-1'));
      await storage.insertRecord(record('x-2'));
      await storage.clearAll();
      expect(await storage.fetchAllForReplay(), isEmpty);
      expect(await storage.fetchPendingBatch(10), isEmpty);
    });

    test('close marks storage closed and subsequent writes throw', () async {
      await storage.close();
      await expectLater(
        storage.insertRecord(record('after-close')),
        throwsA(isA<StateError>()),
      );
    });
  });
}
