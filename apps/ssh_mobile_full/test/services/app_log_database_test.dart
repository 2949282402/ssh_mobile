import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_log_database.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLogDatabase db;
  late AppLogService logs;

  setUp(() async {
    db = AppLogDatabase.forTesting();
    logs = AppLogService.instance;
    logs.clear();
    logs.resetDatabaseForTesting();
  });

  tearDown(() async {
    logs.clear();
    await logs.pendingDbWrites;
    logs.resetDatabaseForTesting();
    await db.close();
  });

  test(
    'startup logs are successfully synchronized to the database upon setDatabase',
    () async {
      // 1. Log before database is set
      logs.info('Startup log 1');
      logs.warning('Startup log 2');

      expect(logs.entries.length, 2);
      expect(logs.activeTimerCount, 1);
      // memory IDs are sequential starting from 1 (or current _nextEntryId)
      final initialId1 = logs.entries[1].id;
      final initialId2 = logs.entries[0].id;
      expect(initialId2 - initialId1, 1);

      // 2. Set the database
      await logs.setDatabase(db);
      await logs.pendingDbWrites;

      expect(logs.databaseOpen, isTrue);

      // Verify memory entries are still present
      expect(logs.entries.length, 2);

      // 3. Verify logs exist in the database
      final dbLogs = await db.appLogDao.getAllLogs();
      expect(dbLogs.length, 2);
      expect(dbLogs[0].message, 'Startup log 1');
      expect(dbLogs[1].message, 'Startup log 2');

      // IDs in database and memory must match and be continuous
      expect(logs.entries[1].id, dbLogs[0].id);
      expect(logs.entries[0].id, dbLogs[1].id);
    },
  );

  test(
    'logs added during database binding keep order and unique IDs',
    () async {
      await db.appLogDao.insertLog(
        AppLogRecordsCompanion(
          id: const drift.Value(40),
          time: drift.Value(
            DateTime.utc(2026, 7, 18, 8).millisecondsSinceEpoch,
          ),
          level: const drift.Value('info'),
          message: const drift.Value('Persisted log'),
        ),
      );
      logs.info('Before binding');

      final bindingReachedCheckpoint = Completer<void>();
      final releaseBinding = Completer<void>();
      final binding = logs.setDatabase(
        db,
        bindingCheckpoint: () async {
          bindingReachedCheckpoint.complete();
          await releaseBinding.future;
        },
      );

      await bindingReachedCheckpoint.future;
      logs.info('During binding 1');
      logs.warning('During binding 2');

      expect(
        logs.entries.map((entry) => entry.message),
        containsAll(<String>['During binding 1', 'During binding 2']),
      );

      releaseBinding.complete();
      await binding;
      await logs.pendingDbWrites;

      var databaseLogs = await db.appLogDao.getAllLogs();
      expect(databaseLogs.map((entry) => entry.message).toList(), <String>[
        'Persisted log',
        'Before binding',
        'During binding 1',
        'During binding 2',
      ]);
      expect(databaseLogs.map((entry) => entry.id).toList(), <int>[
        40,
        41,
        42,
        43,
      ]);
      expect(
        databaseLogs.map((entry) => entry.id).toSet(),
        hasLength(databaseLogs.length),
      );

      final memoryLogs = logs.entries.reversed.toList();
      expect(
        memoryLogs.map((entry) => entry.id).toList(),
        databaseLogs.map((entry) => entry.id).toList(),
      );
      expect(
        memoryLogs.map((entry) => entry.message).toList(),
        databaseLogs.map((entry) => entry.message).toList(),
      );

      logs.info('After binding');
      await logs.pendingDbWrites;
      databaseLogs = await db.appLogDao.getAllLogs();
      expect(databaseLogs.last.id, 44);
      expect(databaseLogs.last.message, 'After binding');
      expect(logs.entries.first.id, 44);
      expect(logs.entries.first.message, 'After binding');
    },
  );
  test(
    'clear during database binding clears persisted and queued logs in order',
    () async {
      await db.appLogDao.insertLog(
        AppLogRecordsCompanion(
          id: const drift.Value(100),
          time: drift.Value(
            DateTime.utc(2026, 7, 18, 9).millisecondsSinceEpoch,
          ),
          level: const drift.Value('info'),
          message: const drift.Value('Persisted A'),
        ),
      );
      await db.appLogDao.insertLog(
        AppLogRecordsCompanion(
          id: const drift.Value(101),
          time: drift.Value(
            DateTime.utc(2026, 7, 18, 9, 1).millisecondsSinceEpoch,
          ),
          level: const drift.Value('info'),
          message: const drift.Value('Persisted B'),
        ),
      );
      logs.info('Before binding');

      final bindingReachedCheckpoint = Completer<void>();
      final releaseBinding = Completer<void>();
      final binding = logs.setDatabase(
        db,
        bindingCheckpoint: () async {
          bindingReachedCheckpoint.complete();
          await releaseBinding.future;
        },
      );

      await bindingReachedCheckpoint.future;
      logs.info('Before clear');
      logs.clear();
      logs.info('After clear');

      expect(logs.entries.map((entry) => entry.message).toList(), <String>[
        'After clear',
      ]);

      releaseBinding.complete();
      await binding;
      await logs.pendingDbWrites;

      final databaseLogs = await db.appLogDao.getAllLogs();
      expect(databaseLogs.map((entry) => entry.message).toList(), <String>[
        'After clear',
      ]);
      expect(databaseLogs.map((entry) => entry.id).toList(), <int>[104]);
      expect(logs.entries.map((entry) => entry.message).toList(), <String>[
        'After clear',
      ]);
      expect(logs.entries.single.id, 104);
    },
  );

  test(
    'delete during database binding removes persisted and queued logs',
    () async {
      await db.appLogDao.insertLog(
        AppLogRecordsCompanion(
          id: const drift.Value(100000),
          time: drift.Value(
            DateTime.utc(2026, 7, 18, 10).millisecondsSinceEpoch,
          ),
          level: const drift.Value('info'),
          message: const drift.Value('Persisted delete'),
        ),
      );
      await db.appLogDao.insertLog(
        AppLogRecordsCompanion(
          id: const drift.Value(100001),
          time: drift.Value(
            DateTime.utc(2026, 7, 18, 10, 1).millisecondsSinceEpoch,
          ),
          level: const drift.Value('info'),
          message: const drift.Value('Persisted keep'),
        ),
      );
      logs.info('Startup keep');

      final bindingReachedCheckpoint = Completer<void>();
      final releaseBinding = Completer<void>();
      final binding = logs.setDatabase(
        db,
        bindingCheckpoint: () async {
          bindingReachedCheckpoint.complete();
          await releaseBinding.future;
        },
      );

      await bindingReachedCheckpoint.future;
      logs.deleteEntriesById(<int>{100000});
      logs.info('Queued delete');
      final queuedDeleteId = logs.entries.first.id;
      logs.deleteEntriesById(<int>{queuedDeleteId});
      logs.info('Queued keep');

      expect(
        logs.entries.map((entry) => entry.message),
        isNot(contains('Queued delete')),
      );

      releaseBinding.complete();
      await binding;
      await logs.pendingDbWrites;

      final databaseLogs = await db.appLogDao.getAllLogs();
      expect(databaseLogs.map((entry) => entry.message).toList(), <String>[
        'Persisted keep',
        'Startup keep',
        'Queued keep',
      ]);
      expect(databaseLogs.map((entry) => entry.id).toList(), <int>[
        100001,
        100002,
        100004,
      ]);

      final memoryLogs = logs.entries.reversed.toList();
      expect(
        memoryLogs.map((entry) => entry.id).toList(),
        databaseLogs.map((entry) => entry.id).toList(),
      );
      expect(
        memoryLogs.map((entry) => entry.message).toList(),
        databaseLogs.map((entry) => entry.message).toList(),
      );
    },
  );
  test(
    'delete during binding does not treat a temporary ID as a persisted ID',
    () async {
      await db.appLogDao.insertLog(
        AppLogRecordsCompanion(
          id: const drift.Value(1),
          time: drift.Value(
            DateTime.utc(2026, 7, 18, 11).millisecondsSinceEpoch,
          ),
          level: const drift.Value('info'),
          message: const drift.Value('Persisted ID 1'),
        ),
      );
      logs.info('Temporary ID 1');
      expect(logs.entries.single.id, 1);

      final bindingReachedCheckpoint = Completer<void>();
      final releaseBinding = Completer<void>();
      final binding = logs.setDatabase(
        db,
        bindingCheckpoint: () async {
          bindingReachedCheckpoint.complete();
          await releaseBinding.future;
        },
      );

      await bindingReachedCheckpoint.future;
      logs.deleteEntriesById(const <int>{1});
      releaseBinding.complete();
      await binding;
      await logs.pendingDbWrites;

      final databaseLogs = await db.appLogDao.getAllLogs();
      expect(databaseLogs, hasLength(1));
      expect(databaseLogs.single.id, 1);
      expect(databaseLogs.single.message, 'Persisted ID 1');
      expect(logs.entries.single.message, 'Persisted ID 1');
    },
  );

  test('detach drains the old database and permits a new binding', () async {
    await logs.setDatabase(db);
    logs.info('Persisted only in the old database');

    final oldDatabase = db;
    await logs.detachDatabase(oldDatabase);
    final drainedLogs = await oldDatabase.appLogDao.getAllLogs();
    expect(
      drainedLogs.map((entry) => entry.message),
      contains('Persisted only in the old database'),
    );
    await oldDatabase.close();

    logs.info('Created after detach');
    await logs.pendingDbWrites;

    db = AppLogDatabase.forTesting();
    await logs.setDatabase(db);
    await logs.pendingDbWrites;

    final replacementLogs = await db.appLogDao.getAllLogs();
    expect(replacementLogs.map((entry) => entry.message).toList(), <String>[
      'Created after detach',
    ]);
  });

  test('new logs are written to database and pruned to 1000 limit', () async {
    await logs.setDatabase(db);
    await logs.pendingDbWrites;

    logs.clear();
    await logs.pendingDbWrites;

    // Write 1005 logs
    for (var i = 1; i <= 1005; i++) {
      logs.info('Log number $i');
    }
    await logs.pendingDbWrites;

    // Memory should have exactly 1000 entries (since _maxEntries is 1000)
    expect(logs.entries.length, 1000);
    // The first entry (newest first) should be 1005, the last should be 6
    expect(logs.entries.first.message, 'Log number 1005');
    expect(logs.entries.last.message, 'Log number 6');

    // Database should have exactly 1000 entries (due to pruneOldLogs)
    final dbLogs = await db.appLogDao.getAllLogs();
    expect(dbLogs.length, 1000);
    expect(dbLogs.first.message, 'Log number 6');
    expect(dbLogs.last.message, 'Log number 1005');
  });

  test('deleteEntriesById deletes from memory and database', () async {
    await logs.setDatabase(db);
    await logs.pendingDbWrites;

    logs.clear();
    await logs.pendingDbWrites;

    logs.info('Log A');
    logs.info('Log B');
    await logs.pendingDbWrites;

    expect(logs.entries.length, 2);
    final idToDelete = logs.entries[0].id; // Log B
    final idToKeep = logs.entries[1].id; // Log A

    // Delete Log B
    logs.deleteEntriesById({idToDelete});
    await logs.pendingDbWrites;

    // Verify memory
    expect(logs.entries.length, 1);
    expect(logs.entries.single.id, idToKeep);
    expect(logs.entries.single.message, 'Log A');

    // Verify database
    final dbLogs = await db.appLogDao.getAllLogs();
    expect(dbLogs.length, 1);
    expect(dbLogs.single.id, idToKeep);
    expect(dbLogs.single.message, 'Log A');
  });

  test('clear clears both memory and database', () async {
    await logs.setDatabase(db);
    await logs.pendingDbWrites;

    logs.info('Log A');
    logs.info('Log B');
    await logs.pendingDbWrites;

    expect(logs.entries.length, 2);

    logs.clear();
    await logs.pendingDbWrites;

    expect(logs.entries.isEmpty, true);

    final dbLogs = await db.appLogDao.getAllLogs();
    expect(dbLogs.isEmpty, true);
  });
}
