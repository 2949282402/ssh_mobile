import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart' as db;
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AppLogService.instance.pendingDbWrites;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLogService.instance.resetDatabaseForTesting();
    AppLogService.instance.clear();
  });

  tearDown(() async {
    await AppLogService.instance.pendingDbWrites;
    AppLogService.instance.resetDatabaseForTesting();
  });

  test('AppDatabase opens in tests', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);

    final result = await database.customSelect('SELECT 1 AS value').getSingle();

    expect(result.read<int>('value'), 1);
  });

  test(
    'early database access and concurrent init reuse one AppDatabase',
    () async {
      var databaseCreations = 0;
      final storage = StorageService(
        databaseFactory: () {
          databaseCreations++;
          return db.AppDatabase.forTesting();
        },
      );
      addTearDown(() async {
        await storage.shutdown();
        await AppLogService.instance.pendingDbWrites;
        AppLogService.instance.resetDatabaseForTesting();
        storage.dispose();
      });

      final earlyDatabase = storage.appDatabase;
      final firstInit = storage.init();
      final secondInit = storage.init();

      expect(identical(firstInit, secondInit), isTrue);
      await Future.wait([firstInit, secondInit, storage.initFuture]);
      await storage.driftInitFuture;

      expect(databaseCreations, 1);
      expect(identical(storage.appDatabase, earlyDatabase), isTrue);
    },
  );
  test(
    'dispose during initialization prevents a late Drift database open',
    () async {
      final initializationStarted = Completer<void>();
      final releaseInitialization = Completer<void>();
      var databaseCreations = 0;
      final storage = StorageService(
        databaseFactory: () {
          databaseCreations++;
          return db.AppDatabase.forTesting();
        },
        initializationCheckpoint: () async {
          initializationStarted.complete();
          await releaseInitialization.future;
        },
      );

      final initialization = storage.init();
      await initializationStarted.future;
      storage.dispose();
      final shutdown = storage.shutdown();
      releaseInitialization.complete();

      await Future.wait(<Future<void>>[initialization, shutdown]);

      expect(databaseCreations, 0);
      expect(() => storage.appDatabase, throwsStateError);
    },
  );

  test(
    'awaited shutdown permits sequential database owners without overlap',
    () async {
      var activeDatabases = 0;
      var maximumActiveDatabases = 0;
      var databaseCreations = 0;
      var databaseCloseInvocations = 0;
      var databaseCloses = 0;

      db.AppDatabase createDatabase() {
        databaseCreations++;
        return _TrackingAppDatabase(
          onCreated: () {
            activeDatabases++;
            if (activeDatabases > maximumActiveDatabases) {
              maximumActiveDatabases = activeDatabases;
            }
          },
          onCloseInvoked: () => databaseCloseInvocations++,
          onClosed: () {
            activeDatabases--;
            databaseCloses++;
          },
        );
      }

      final first = StorageService(databaseFactory: createDatabase);
      StorageService? second;
      try {
        final firstDatabase = first.appDatabase;
        await first.init();
        await first.driftInitFuture;
        expect(databaseCreations, 1);

        AppLogService.instance.info('Written through first database');
        await first.shutdown();
        expect(activeDatabases, 0);

        second = StorageService(databaseFactory: createDatabase);
        final secondDatabase = second.appDatabase;
        await second.init();
        await second.driftInitFuture;

        expect(databaseCreations, 2);
        expect(identical(firstDatabase, secondDatabase), isFalse);
        expect(maximumActiveDatabases, 1);

        AppLogService.instance.info('Written through second database');
        await AppLogService.instance.pendingDbWrites;
        final secondLogs = await secondDatabase.appLogDao.getAllLogs();
        expect(
          secondLogs.map((entry) => entry.message),
          contains('Written through second database'),
        );

        await second.shutdown();
        expect(activeDatabases, 0);
        expect(databaseCloseInvocations, 2);
        expect(databaseCloses, 2);
      } finally {
        await first.shutdown();
        first.dispose();
        if (second != null) {
          await second.shutdown();
          second.dispose();
        }
      }
    },
  );

  test('explicit shutdown reports a Drift close failure', () async {
    final database = _FailingCloseAppDatabase();
    final storage = StorageService(databaseFactory: () => database);
    try {
      storage.appDatabase;
      await storage.init();
      await storage.driftInitFuture;

      await expectLater(storage.shutdown(), throwsStateError);
      expect(database.closeInvocations, 1);
    } finally {
      await database.close();
      storage.dispose();
    }
  });

  test('encrypts Playbook content in Drift and roundtrips', () async {
    const secret = 'SECRET_PLAYBOOK_MARKER_20260621';
    final now = DateTime.utc(2026, 6, 21, 4);
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    await storage.init();

    await storage.savePlaybook(
      Playbook(
        id: 'playbook-secret',
        name: 'Secret playbook',
        description: 'Contains a secret marker',
        steps: [
          PlaybookStep(
            id: 'step-secret',
            name: 'Echo',
            command: 'echo $secret',
            description: 'Print marker',
            stdout: 'stdout $secret',
            stderr: 'stderr $secret',
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final raw = await database
        .customSelect('SELECT content_json FROM playbooks')
        .getSingle();
    expect(raw.read<String>('content_json'), isNot(contains(secret)));

    await storage.shutdown();
    storage.dispose();
    final restarted = StorageService(database: database);
    addTearDown(() => _shutdownAndDispose(restarted));
    await restarted.init();

    final loaded = (await restarted.loadPlaybooks()).single;
    expect(loaded.steps.single.command, contains(secret));
    expect(loaded.steps.single.stdout, contains(secret));
    expect(loaded.steps.single.stderr, contains(secret));
  });
}

Future<void> _shutdownAndDispose(StorageService storage) async {
  await storage.shutdown();
  storage.dispose();
}

class _TrackingAppDatabase extends db.AppDatabase {
  _TrackingAppDatabase({
    required this.onCreated,
    required this.onCloseInvoked,
    required this.onClosed,
  }) : super.forTesting() {
    onCreated();
  }

  final void Function() onCreated;
  final void Function() onCloseInvoked;
  final void Function() onClosed;
  bool _closed = false;

  @override
  Future<void> close() async {
    onCloseInvoked();
    if (_closed) return;
    _closed = true;
    try {
      await super.close();
    } finally {
      onClosed();
    }
  }
}

class _FailingCloseAppDatabase extends db.AppDatabase {
  _FailingCloseAppDatabase() : super.forTesting();

  int closeInvocations = 0;
  bool _failNextClose = true;

  @override
  Future<void> close() async {
    closeInvocations++;
    if (_failNextClose) {
      _failNextClose = false;
      throw StateError('forced database close failure');
    }
    await super.close();
  }
}
