import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' as drift;
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

  test('AI chat DAO loads paged summaries and messages separately', () async {
    final base = DateTime.utc(2026, 6, 21, 11);
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);

    for (var i = 0; i < 3; i++) {
      final created = base.add(Duration(minutes: i));
      await database.aiChatDao.saveChat(
        db.AiChatsCompanion(
          id: drift.Value('chat-$i'),
          title: drift.Value('Chat $i'),
          model: const drift.Value('model-a'),
          createdAt: drift.Value(created.millisecondsSinceEpoch),
          updatedAt: drift.Value(created.millisecondsSinceEpoch),
        ),
        [
          db.AiChatMessagesCompanion(
            id: drift.Value('chat-$i:message-2'),
            chatId: drift.Value('chat-$i'),
            role: const drift.Value('assistant'),
            textContent: drift.Value('second $i'),
            createdAt: drift.Value(
              created.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
            ),
            attachmentsJson: const drift.Value('[]'),
            tracesJson: const drift.Value('[]'),
            todoStepsJson: const drift.Value('[]'),
          ),
          db.AiChatMessagesCompanion(
            id: drift.Value('chat-$i:message-1'),
            chatId: drift.Value('chat-$i'),
            role: const drift.Value('user'),
            textContent: drift.Value('first $i'),
            createdAt: drift.Value(
              created.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
            ),
            attachmentsJson: const drift.Value('[]'),
            tracesJson: const drift.Value('[]'),
            todoStepsJson: const drift.Value('[]'),
          ),
        ],
      );
    }

    final summaries = await database.aiChatDao.loadChatSummaries(
      limit: 2,
      offset: 1,
    );
    expect(summaries.map((chat) => chat.id).toList(), ['chat-1', 'chat-0']);

    final messages = await database.aiChatDao.loadMessagesForChat('chat-1');
    expect(messages.map((message) => message.id).toList(), [
      'chat-1:message-1',
      'chat-1:message-2',
    ]);
  });

  test('stores agent metrics in Drift with latest 200 retention', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(() => _shutdownAndDispose(storage));
    await storage.init();

    final base = DateTime.utc(2026, 6, 21);
    for (var i = 0; i < 205; i++) {
      await storage.saveAgentRunMetrics(
        AgentRunMetrics(
          id: 'metric-$i',
          startedAt: base.add(Duration(minutes: i)),
          finishedAt: base.add(Duration(minutes: i, seconds: 10)),
          model: 'model-${i % 2}',
          promptTokens: i,
          completionTokens: i + 1,
          totalTokens: i + 2,
          elapsedMs: 10,
        ),
      );
    }

    final metrics = await storage.loadAgentRunMetrics();
    expect(metrics, hasLength(200));
    expect(metrics.first.id, 'metric-204');
    expect(metrics.last.id, 'metric-5');
  });

  test('encrypts AI chat sensitive fields in Drift and roundtrips', () async {
    const secret = 'SECRET_AI_MARKER_20260621';
    final now = DateTime.utc(2026, 6, 21, 3);
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    await storage.init();

    await storage.saveAiChat(
      AiChatRecord(
        id: 'chat-secret',
        title: 'Secret chat',
        model: 'model-a',
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'message $secret',
            contextText: 'context $secret',
            attachments: [
              AiChatAttachment(
                fileName: 'secret.txt',
                mimeType: 'text/plain',
                sizeBytes: secret.length,
                dataBase64: base64Encode(utf8.encode(secret)),
              ),
            ],
            traces: [
              AiMessageTrace(
                id: 'trace-secret',
                kind: 'tool',
                title: 'Trace',
                content: 'trace $secret',
                createdAt: now,
              ),
            ],
            todoSteps: const [
              AiTodoStep(
                id: 'task-secret',
                name: 'Task',
                command: 'echo secret',
                description: 'Task description',
                stdout: 'stdout SECRET_AI_MARKER_20260621',
                stderr: 'stderr SECRET_AI_MARKER_20260621',
              ),
            ],
            createdAt: now,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final raw = await database
        .customSelect(
          'SELECT text, context_text, attachments_json, traces_json, '
          'todo_steps_json FROM ai_chat_messages',
        )
        .getSingle();
    expect(raw.read<String>('text'), isNot(contains(secret)));
    expect(raw.read<String>('context_text'), isNot(contains(secret)));
    expect(raw.read<String>('attachments_json'), isNot(contains(secret)));
    expect(raw.read<String>('traces_json'), isNot(contains(secret)));
    expect(raw.read<String>('todo_steps_json'), isNot(contains(secret)));

    await storage.shutdown();
    storage.dispose();
    final restarted = StorageService(database: database);
    addTearDown(() => _shutdownAndDispose(restarted));
    await restarted.init();

    final loaded = (await restarted.loadAiChats()).single.messages.single;
    expect(loaded.text, contains(secret));
    expect(loaded.contextText, contains(secret));
    expect(
      loaded.attachments.single.dataBase64,
      base64Encode(utf8.encode(secret)),
    );
    expect(loaded.traces.single.content, contains(secret));
    expect(loaded.todoSteps.single.stdout, contains(secret));
    expect(loaded.todoSteps.single.stderr, contains(secret));
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
