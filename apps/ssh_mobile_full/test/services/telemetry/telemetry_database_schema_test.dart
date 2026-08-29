// Telemetry Drift schema, migration, and platform-connection tests.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_database.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_connection.dart'
    as connection;
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_connection_stub.dart'
    as stub;
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_constants.dart';

void main() {
  test('telemetry constants and native connection factory are usable', () {
    expect(telemetryDatabaseName, 'telemetry');

    final executor = connection.openTelemetryDatabaseConnection();
    expect(executor, isA<QueryExecutor>());
    addTearDown(() async {
      await executor.close();
    });
  });

  test('stub connection throws UnsupportedError on unsupported platforms', () {
    expect(stub.openTelemetryDatabaseConnection, throwsUnsupportedError);
  });

  test(
    'database opens, migrates from v1, and upgrades policy storage',
    () async {
      // Seed the v1 records schema and its sqlite user_version before Drift
      // opens, so the real MigrationStrategy's onUpgrade path runs.
      final database = TelemetryDatabase(
        executor: NativeDatabase.memory(
          setup: (database) {
            database.execute('''
            CREATE TABLE telemetry_records (
              event_id TEXT NOT NULL UNIQUE,
              record_type TEXT NOT NULL,
              event_name TEXT NOT NULL,
              event_version INTEGER NOT NULL,
              device_id TEXT NOT NULL,
              session_id TEXT NOT NULL,
              trace_id TEXT NOT NULL,
              occurred_at TEXT NOT NULL,
              feature TEXT NOT NULL,
              severity TEXT NOT NULL,
              app_version TEXT NOT NULL,
              build_number TEXT NOT NULL,
              platform TEXT NOT NULL,
              properties TEXT NOT NULL,
              error TEXT,
              sync_state TEXT NOT NULL,
              logical_deleted_at TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL
            )
          ''');
            database.execute('PRAGMA user_version = 1');
          },
        ),
      );
      addTearDown(() => database.dispose());

      await database
          .customSelect('SELECT release_channel FROM telemetry_records LIMIT 1')
          .get();
      await database
          .customSelect('SELECT id FROM telemetry_policy_states LIMIT 1')
          .get();

      final records = await database.telemetryRecordsDao.fetchAll();
      expect(records, isEmpty);
    },
  );
}
