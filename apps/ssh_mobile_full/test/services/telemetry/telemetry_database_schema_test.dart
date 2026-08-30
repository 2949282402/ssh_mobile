// Telemetry Drift schema, migration, and platform-connection tests.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_database.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_connection.dart'
    as connection;
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_connection_io.dart'
    as io_connection;
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_connection_stub.dart'
    as stub;
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_connection_web.dart'
    as web_connection;
import 'package:ssh_mobile/services/telemetry/telemetry_database/telemetry_database_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('telemetry constants and native connection factory are usable', () {
    expect(telemetryDatabaseName, 'telemetry');

    final executor = connection.openTelemetryDatabaseConnection();
    expect(executor, isA<QueryExecutor>());
    addTearDown(() async {
      await executor.close();
    });
  });

  test(
    'native connection creates the support directory for production mode',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ssh-mobile-telemetry-',
      );
      addTearDown(() => root.delete(recursive: true));
      final supportDirectory = Directory(p.join(root.path, 'support'));
      final executor = io_connection.openTelemetryDatabaseConnection(
        directoryProvider: () async => supportDirectory,
      );
      final database = TelemetryDatabase(executor: executor);
      addTearDown(database.dispose);

      await database.customSelect('SELECT 1').get();

      expect(await supportDirectory.exists(), isTrue);
      expect(
        await File(p.join(supportDirectory.path, 'telemetry.sqlite')).exists(),
        isTrue,
      );
    },
  );

  test('schema exposes record columns, policy state, and sync indexes', () async {
    final database = TelemetryDatabase(executor: NativeDatabase.memory());
    addTearDown(database.dispose);

    final columns = await database
        .customSelect('PRAGMA table_info(telemetry_records)')
        .get();
    expect(
      columns.map((row) => row.data['name']),
      containsAll(<Object?>[
        'event_id',
        'record_type',
        'release_channel',
        'properties',
        'sync_state',
        'retry_count',
        'created_at',
      ]),
    );
    final policyColumns = await database
        .customSelect('PRAGMA table_info(telemetry_policy_states)')
        .get();
    expect(policyColumns.map((row) => row.data['name']).toList(), <Object?>[
      'id',
      'policy_json',
      'policy_version',
      'updated_at',
    ]);

    final indexes = await database
        .customSelect('PRAGMA index_list(telemetry_records)')
        .get();
    expect(
      indexes.map((row) => row.data['name']),
      containsAll(<Object?>[
        'idx_telemetry_records_event_id',
        'idx_telemetry_records_sync_created',
      ]),
    );
    final indexSql = await database
        .customSelect(
          "SELECT sql FROM sqlite_master WHERE name = 'idx_telemetry_records_sync_created'",
        )
        .getSingle();
    expect(indexSql.data['sql'], contains('sync_state, created_at'));
  });

  test('stub connection throws UnsupportedError on unsupported platforms', () {
    expect(stub.openTelemetryDatabaseConnection, throwsUnsupportedError);
  });

  test('web connection wrapper exposes a Drift executor contract', () async {
    final root = await Directory.systemTemp.createTemp('telemetry-web-');
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previousPathProvider;
      await root.delete(recursive: true);
    });

    final executor = web_connection.openTelemetryDatabaseConnection();
    expect(executor, isA<QueryExecutor>());
    addTearDown(executor.close);
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

final class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}
