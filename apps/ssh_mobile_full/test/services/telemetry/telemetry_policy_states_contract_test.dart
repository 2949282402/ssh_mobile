// TelemetryPolicyStates durable policy contract: store, read, version, and
// updatedAt timestamp behavior used by DriftTelemetryStorage.

import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/drift_telemetry_storage.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_database.dart';

const _policyV3 = TelemetryUploadPolicy(
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

const _policyV5 = TelemetryUploadPolicy(
  uploadEnabled: true,
  batchSizeThreshold: 9,
  timeIntervalSeconds: 120,
  maxBatchSize: 32,
  clientMaxLocalRecords: 200,
  specialTriggers: ['networkRecovered', 'appForegroundWithBacklog'],
  policyVersion: 5,
);

void main() {
  group('TelemetryPolicyStates policy contract', () {
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
      'stores the policy row and restores it with its durable timestamp',
      () async {
        final writeStartedAt = DateTime.now().toUtc();

        await storage.saveLastKnownGoodPolicy(_policyV3);

        final row = await database.telemetryRecordsDao
            .fetchLastKnownGoodPolicy();
        expect(row, isNotNull);
        expect(row!.id, 1);
        expect(row.policyVersion, 3);
        final durableWriteAt = row.updatedAt.toUtc();
        expect(
          durableWriteAt.isAfter(
            writeStartedAt.subtract(const Duration(seconds: 1)),
          ),
          isTrue,
        );
        expect(
          durableWriteAt.isBefore(
            DateTime.now().toUtc().add(const Duration(seconds: 1)),
          ),
          isTrue,
        );
        expect(jsonDecode(row.policyJson), isA<Map<String, dynamic>>());

        final restored = await storage.loadLastKnownGoodPolicy();
        expect(restored, isNotNull);
        expect(restored!.policyVersion, 3);
        expect(restored.batchSizeThreshold, 7);
        expect(restored.timeIntervalSeconds, 60);
      },
    );

    test('keeps the newest policy version during conflicting writes', () async {
      await storage.saveLastKnownGoodPolicy(_policyV3);
      await storage.saveLastKnownGoodPolicy(_policyV5);
      await storage.saveLastKnownGoodPolicy(_policyV3);

      final row = await database.telemetryRecordsDao.fetchLastKnownGoodPolicy();
      expect(row, isNotNull);
      expect(row!.policyVersion, 5);
      expect(await storage.loadLastKnownGoodPolicy(), isNotNull);
      expect((await storage.loadLastKnownGoodPolicy())!.policyVersion, 5);
    });

    test(
      'rejects a row whose denormalized version does not match the JSON',
      () async {
        await database
            .into(database.telemetryPolicyStates)
            .insert(
              TelemetryPolicyStatesCompanion.insert(
                id: const Value(1),
                policyJson: jsonEncode(_policyV3.toJson()),
                policyVersion: 99,
                updatedAt: DateTime.utc(2026, 8, 29),
              ),
            );

        expect(await storage.loadLastKnownGoodPolicy(), isNull);
      },
    );
  });
}
