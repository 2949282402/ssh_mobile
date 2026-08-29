import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ssh_mobile/services/app_log_database.dart';
import 'package:ssh_mobile/services/app_log_database_connection_io.dart'
    as io_connection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLogDatabase database;

  setUp(() {
    database = AppLogDatabase.forTesting();
  });

  tearDown(() async {
    await database.dispose();
  });

  test(
    'schema exposes the durable log columns and descending time index',
    () async {
      final columns = await database
          .customSelect('PRAGMA table_info(app_log_records)')
          .get();
      expect(columns.map((row) => row.data['name']).toList(), <Object?>[
        'id',
        'time',
        'level',
        'message',
        'source_location',
        'stack_trace',
        'details',
      ]);

      final indexes = await database
          .customSelect('PRAGMA index_list(app_log_records)')
          .get();
      expect(
        indexes.map((row) => row.data['name']),
        contains('idx_app_log_time'),
      );
      final indexSql = await database
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE name = 'idx_app_log_time'",
          )
          .getSingle();
      expect(indexSql.data['sql'], contains('time DESC'));
    },
  );

  test(
    'DAO preserves optional fields and supports deletion and clearing',
    () async {
      final firstId = await database.appLogDao.insertLog(
        AppLogRecordsCompanion.insert(
          time: 10,
          level: 'info',
          message: 'first',
          sourceLocation: const drift.Value('source.dart:10'),
          stackTrace: const drift.Value('trace'),
          details: const drift.Value('{"key":"value"}'),
        ),
      );
      final secondId = await database.appLogDao.insertLog(
        AppLogRecordsCompanion.insert(
          time: 20,
          level: 'error',
          message: 'second',
        ),
      );

      final rows = await database.appLogDao.getAllLogs();
      expect(rows.map((row) => row.id).toList(), <int>[firstId, secondId]);
      expect(rows.first.sourceLocation, 'source.dart:10');
      expect(rows.first.stackTrace, 'trace');
      expect(rows.first.details, '{"key":"value"}');
      expect(rows.last.sourceLocation, isNull);

      await database.appLogDao.deleteLogs(<int>{firstId});
      expect((await database.appLogDao.getAllLogs()).single.id, secondId);
      await database.appLogDao.deleteLogs(const <int>{});
      await database.appLogDao.clearAllLogs();
      expect(await database.appLogDao.getAllLogs(), isEmpty);
    },
  );

  test('factory and dispose are safe for the Flutter test executor', () async {
    await database.dispose();
    final productionStyle = AppLogDatabase();
    addTearDown(productionStyle.dispose);
    expect(productionStyle.schemaVersion, 1);
    await productionStyle.appLogDao.getAllLogs();
    await productionStyle.dispose();
    await productionStyle.dispose();
  });

  test(
    'native connection creates the support directory for production mode',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ssh-mobile-app-logs-',
      );
      addTearDown(() => root.delete(recursive: true));
      final supportDirectory = Directory(p.join(root.path, 'support'));
      final executor = io_connection.openAppLogDatabaseConnection(
        directoryProvider: () async => supportDirectory,
      );
      final database = AppLogDatabase(executor: executor);
      addTearDown(database.dispose);

      await database.appLogDao.getAllLogs();

      expect(await supportDirectory.exists(), isTrue);
      expect(
        await File(p.join(supportDirectory.path, 'app_logs.sqlite')).exists(),
        isTrue,
      );
    },
  );
}
