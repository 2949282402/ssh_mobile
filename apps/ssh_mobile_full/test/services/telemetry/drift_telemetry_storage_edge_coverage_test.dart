// 遥测 SQLite 存储的边界与恢复路径测试。

import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/drift_telemetry_storage.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_database.dart';

TelemetryEventRecord _record(
  String id, {
  TelemetrySyncState syncState = TelemetrySyncState.pending,
  DateTime? occurredAt,
  TelemetryErrorDetail? error,
  DateTime? logicalDeletedAt,
  int retryCount = 0,
}) {
  return TelemetryEventRecord(
    eventId: id,
    recordType: TelemetryRecordType.analytics,
    eventName: 'edge.event',
    eventVersion: 1,
    deviceId: 'device',
    sessionId: 'session',
    traceId: 'trace-$id',
    occurredAt: occurredAt ?? DateTime.utc(2026, 8, 29),
    feature: 'test',
    severity: TelemetrySeverity.info,
    appVersion: '1.0',
    buildNumber: '1',
    platform: 'linux',
    properties: {'id': id},
    error: error,
    syncState: syncState,
    logicalDeletedAt: logicalDeletedAt,
    retryCount: retryCount,
  );
}

TelemetryUploadPolicy _policy(int version) => TelemetryUploadPolicy(
  uploadEnabled: true,
  batchSizeThreshold: 5,
  timeIntervalSeconds: 30,
  maxBatchSize: 20,
  clientMaxLocalRecords: 1000,
  specialTriggers: const ['networkRecovered'],
  policyVersion: version,
);

void main() {
  group('DriftTelemetryStorage edge behavior', () {
    late TelemetryDatabase database;
    late DriftTelemetryStorage storage;

    setUp(() {
      database = TelemetryDatabase(executor: NativeDatabase.memory());
      storage = DriftTelemetryStorage(database: database);
    });

    tearDown(() async {
      await storage.close();
    });

    test(
      'uses the default pending batch limit for non-positive limits',
      () async {
        for (var i = 0; i < 3; i++) {
          await storage.insertRecord(_record('limit-$i'));
        }
        expect((await storage.fetchPendingBatch(0)).length, 3);
        expect((await storage.fetchPendingBatch(-1)).length, 3);
      },
    );

    test('round-trips all sync states and error details', () async {
      final error = const TelemetryErrorDetail(
        errorCode: 'E_EDGE',
        category: 'storage',
        terminalFailure: false,
        message: 'not fatal',
        stackTrace: 'stack',
      );
      await storage.insertRecord(
        _record('new', syncState: TelemetrySyncState.new_, error: error),
      );
      await storage.insertRecord(_record('pending'));
      await storage.insertRecord(
        _record(
          'synced',
          syncState: TelemetrySyncState.synced,
          logicalDeletedAt: DateTime.utc(2026, 8, 29, 1),
          retryCount: 2,
        ),
      );
      await storage.insertRecord(
        _record('rejected', syncState: TelemetrySyncState.rejected),
      );

      final rows = await storage.fetchAllForReplay();
      final byId = {for (final row in rows) row.eventId: row};
      expect(byId['new']!.syncState, TelemetrySyncState.new_);
      expect(byId['pending']!.syncState, TelemetrySyncState.pending);
      expect(byId['synced']!.syncState, TelemetrySyncState.synced);
      expect(byId['rejected']!.syncState, TelemetrySyncState.rejected);
      expect(byId['new']!.error!.errorCode, error.errorCode);
      expect(byId['new']!.error!.category, error.category);
      expect(byId['new']!.error!.terminalFailure, error.terminalFailure);
      expect(byId['new']!.error!.message, error.message);
      expect(byId['new']!.error!.stackTrace, error.stackTrace);
      expect(byId['synced']!.logicalDeletedAt, isNotNull);
      expect(byId['synced']!.retryCount, 2);
    });

    test('fetches rejected records in durable order for replay', () async {
      await storage.insertRecord(
        _record(
          'rejected-newer',
          syncState: TelemetrySyncState.rejected,
          occurredAt: DateTime.utc(2026, 8, 29, 2),
        ),
      );
      await storage.insertRecord(
        _record(
          'rejected-older',
          syncState: TelemetrySyncState.rejected,
          occurredAt: DateTime.utc(2026, 8, 29, 1),
        ),
      );
      await storage.insertRecord(_record('pending'));

      final rejected = await storage.fetchRejectedForReplay();

      expect(rejected.map((record) => record.eventId), <String>[
        'rejected-newer',
        'rejected-older',
      ]);
      expect(
        rejected.every((record) {
          return record.syncState == TelemetrySyncState.rejected;
        }),
        isTrue,
      );
    });

    test('unknown persisted sync values fail closed to pending', () async {
      await database
          .into(database.telemetryRecords)
          .insert(
            TelemetryRecordsCompanion.insert(
              eventId: 'unknown-state',
              recordType: 'analytics',
              eventName: 'edge.event',
              eventVersion: 1,
              deviceId: 'device',
              sessionId: 'session',
              traceId: 'trace',
              occurredAt: DateTime.utc(2026, 8, 29).toIso8601String(),
              feature: 'test',
              severity: 'info',
              appVersion: '1',
              buildNumber: '1',
              platform: 'linux',
              properties: jsonEncode(const <String, dynamic>{}),
              syncState: 'unexpected',
              createdAt: DateTime.utc(2026, 8, 29),
            ),
          );

      final row = (await storage.fetchAllForReplay()).single;
      expect(row.syncState, TelemetrySyncState.pending);
    });

    test('malformed and incomplete durable policies are ignored', () async {
      final malformed = <String, dynamic>{
        'uploadEnabled': true,
        'batchSizeThreshold': 5,
        'timeIntervalSeconds': 30,
        'maxBatchSize': 20,
        'clientMaxLocalRecords': 1000,
        'specialTriggers': const ['networkRecovered'],
        'policyVersion': 2,
      };

      Future<void> insertPolicy(Object policyJson, {int version = 2}) async {
        await database
            .into(database.telemetryPolicyStates)
            .insert(
              TelemetryPolicyStatesCompanion.insert(
                id: const Value(1),
                policyJson: policyJson is String
                    ? policyJson
                    : jsonEncode(policyJson),
                policyVersion: version,
                updatedAt: DateTime.utc(2026, 8, 29),
              ),
            );
        expect(await storage.loadLastKnownGoodPolicy(), isNull);
        await database.delete(database.telemetryPolicyStates).go();
      }

      await insertPolicy('{not-json');
      await insertPolicy(const <String>['not-a-map']);
      await insertPolicy({...malformed, 'extra': true});
      await insertPolicy({
        ...malformed,
        'specialTriggers': <dynamic>[1],
      });
      await insertPolicy({
        ...malformed,
        'specialTriggers': const ['unknown'],
      });
      await insertPolicy({...malformed, 'policyVersion': 0}, version: 0);
      await insertPolicy({...malformed, 'batchSizeThreshold': 0});
    });

    test('newer policy is retained over an older replacement', () async {
      await storage.saveLastKnownGoodPolicy(_policy(5));
      await storage.saveLastKnownGoodPolicy(_policy(3));
      final restored = await storage.loadLastKnownGoodPolicy();
      expect(restored!.policyVersion, 5);
    });

    test(
      'ack and retry operations are idempotent for empty or unknown input',
      () async {
        await storage.insertRecord(_record('retry'));
        await storage.applyAckResults(const <TelemetryAckResult>[]);
        await storage.applyAckResults(const [
          TelemetryAckResult(eventId: 'missing', status: 'already_seen'),
          TelemetryAckResult(eventId: 'retry', status: 'ignored'),
        ]);
        await storage.applyRetryCount(const [], increment: 4);
        await storage.applyRetryCount(const ['retry'], increment: 0);
        expect((await storage.fetchAllForReplay()).single.retryCount, 0);
        await expectLater(
          storage.applyRetryCount(const ['retry'], increment: -1),
          throwsArgumentError,
        );
      },
    );

    test('retry increments are chunked and ignore missing ids', () async {
      final ids = <String>[];
      for (var i = 0; i < 205; i++) {
        final id = 'chunk-$i';
        ids.add(id);
        await storage.insertRecord(_record(id));
      }
      await storage.applyRetryCount([...ids, 'missing'], increment: 2);
      final rows = await storage.fetchAllForReplay();
      expect(rows.every((row) => row.retryCount == 2), isTrue);
    });

    test(
      'purge returns zero without work and caches health snapshots',
      () async {
        expect(storage.cachedHealthStats, isNull);
        expect(await storage.purgeOldSyncedRecords(targetCapacity: 0), 0);
        await storage.insertRecord(_record('one'));
        expect(await storage.purgeOldSyncedRecords(targetCapacity: 5), 0);
        final health = await storage.getHealthStats(targetCapacity: 5);
        expect(storage.cachedHealthStats, same(health));
        expect(health.totalCount, 1);
        expect(health.cacheOverflow, isFalse);
      },
    );

    test(
      'closed storage rejects every query and keeps close/clear idempotent',
      () async {
        await storage.insertRecord(_record('before-close'));
        await storage.close();
        await storage.close();
        await storage.clearAll();
        final failures = <Future<void>>[
          storage.loadLastKnownGoodPolicy().then<void>((_) {}, onError: (_) {}),
        ];
        expect(
          () => storage.loadLastKnownGoodPolicy(),
          throwsA(isA<StateError>()),
        );
        expect(() => storage.fetchPendingBatch(1), throwsA(isA<StateError>()));
        expect(
          () => storage.applyAckResults(const []),
          throwsA(isA<StateError>()),
        );
        expect(
          () => storage.applyRetryCount(const [], increment: 1),
          throwsA(isA<StateError>()),
        );
        expect(() => storage.fetchAllForReplay(), throwsA(isA<StateError>()));
        expect(
          () => storage.purgeOldSyncedRecords(targetCapacity: 1),
          throwsA(isA<StateError>()),
        );
        expect(
          () => storage.getHealthStats(targetCapacity: 1),
          throwsA(isA<StateError>()),
        );
        expect(
          () => storage.saveLastKnownGoodPolicy(_policy(1)),
          throwsA(isA<StateError>()),
        );
        await Future.wait(failures);
      },
    );
  });
}
