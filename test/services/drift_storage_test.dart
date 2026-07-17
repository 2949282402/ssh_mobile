import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart' as db;
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

part 'drift_storage_migration_tests.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLogService.instance.clear();
  });

  test('AppDatabase opens in tests', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);

    final result = await database.customSelect('SELECT 1 AS value').getSingle();

    expect(result.read<int>('value'), 1);
  });

  test('drift init failure falls back to protected pref storage', () async {
    final now = DateTime.utc(2026, 6, 21, 10);
    final legacyChat = AiChatRecord(
      id: 'legacy-pref-chat',
      title: 'Legacy pref',
      model: 'model-a',
      messages: [
        AiChatMessageRecord(
          role: 'assistant',
          text: 'legacy pref message',
          createdAt: now,
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
    final legacyMetric = AgentRunMetrics(
      id: 'legacy-pref-metric',
      startedAt: now,
      finishedAt: now.add(const Duration(seconds: 1)),
      model: 'model-a',
      promptTokens: 1,
      completionTokens: 2,
      totalTokens: 3,
      elapsedMs: 1000,
    );
    final legacyTerminal = TerminalHistoryRecord(
      sessionId: 'legacy-pref-terminal',
      connectionId: 'server-1',
      connectionName: 'Prod',
      displayName: 'Prod shell',
      tmuxSessionName: 'tmux-prod',
      state: 'disconnected',
      errorMessage: null,
      createdAt: now,
      updatedAt: now,
    );
    final legacyPlaybook = Playbook(
      id: 'legacy-pref-playbook',
      name: 'Legacy pref playbook',
      description: 'Loaded from protected pref fallback',
      steps: [
        PlaybookStep(
          id: 'legacy-pref-step',
          name: 'Check',
          command: 'uptime',
          description: 'Check server',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
    SharedPreferences.setMockInitialValues({
      'ai_chats': jsonEncode([legacyChat.toJson()]),
      'agent_run_metrics': jsonEncode([legacyMetric.toJson()]),
      'terminal_history_records': jsonEncode([legacyTerminal.toJson()]),
      'custom_playbooks': jsonEncode([legacyPlaybook.toJson()]),
    });

    final failingDatabase = _failingDatabase();
    addTearDown(() => _closeIgnoringErrors(failingDatabase));
    final storage = StorageService(database: failingDatabase);
    addTearDown(storage.dispose);
    await storage.init();

    expect((await storage.loadAiChats()).single.id, 'legacy-pref-chat');
    expect(
      (await storage.loadAgentRunMetrics()).single.id,
      'legacy-pref-metric',
    );
    expect(
      (await storage.loadTerminalHistoryRecords()).single.sessionId,
      'legacy-pref-terminal',
    );
    expect((await storage.loadPlaybooks()).single.id, 'legacy-pref-playbook');
    expect(
      AppLogService.instance.entries.any(
        (entry) => entry.message.contains('Failed to initialize Drift storage'),
      ),
      isTrue,
    );

    final savedChat = AiChatRecord(
      id: 'saved-pref-chat',
      title: 'Saved pref',
      model: 'model-a',
      messages: [
        AiChatMessageRecord(
          role: 'assistant',
          text: 'saved through protected pref fallback',
          createdAt: now.add(const Duration(minutes: 1)),
        ),
      ],
      createdAt: now.add(const Duration(minutes: 1)),
      updatedAt: now.add(const Duration(minutes: 1)),
    );
    await storage.saveAiChat(savedChat);
    await storage.flushPendingWrites();

    final restartedDatabase = _failingDatabase();
    addTearDown(() => _closeIgnoringErrors(restartedDatabase));
    final restarted = StorageService(database: restartedDatabase);
    addTearDown(restarted.dispose);
    await restarted.init();

    final loadedIds = (await restarted.loadAiChats())
        .map((chat) => chat.id)
        .toList(growable: false);
    expect(loadedIds, contains('saved-pref-chat'));
    expect(loadedIds, contains('legacy-pref-chat'));
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

  test(
    'migrates legacy AI chats to Drift and preserves message payloads',
    () async {
      final now = DateTime.utc(2026, 6, 21, 1, 2, 3);
      final chat = AiChatRecord(
        id: 'chat-1',
        title: 'Plan',
        model: 'model-a',
        planMode: true,
        approvedPlan: AiApprovedPlanRef(
          assistantCreatedAt: now,
          approvedAt: now.add(const Duration(minutes: 1)),
        ),
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'done',
            createdAt: now,
            attachments: const [
              AiChatAttachment(
                fileName: 'notes.txt',
                mimeType: 'text/plain',
                sizeBytes: 5,
                dataBase64: 'aGVsbG8=',
              ),
            ],
            traces: [
              AiMessageTrace(
                id: 'trace-1',
                kind: 'tool',
                title: 'Tool',
                content: '{}',
                createdAt: now,
              ),
            ],
            todoSteps: const [
              AiTodoStep(
                id: 'task-1',
                name: 'Check',
                command: 'uptime',
                description: 'Check uptime',
              ),
            ],
          ),
        ],
        createdAt: now,
        updatedAt: now,
      );
      SharedPreferences.setMockInitialValues({
        'ai_chats': jsonEncode([chat.toJson()]),
      });

      final database = db.AppDatabase.forTesting();
      addTearDown(database.close);
      final storage = StorageService(database: database);
      addTearDown(storage.dispose);
      await storage.init();

      final loaded = await storage.loadAiChats();
      expect(loaded, hasLength(1));
      expect(loaded.single.planMode, isTrue);
      expect(
        loaded.single.approvedPlan?.approvedAt,
        now.add(const Duration(minutes: 1)),
      );
      expect(
        loaded.single.messages.single.attachments.single.fileName,
        'notes.txt',
      );
      expect(loaded.single.messages.single.traces.single.id, 'trace-1');
      expect(loaded.single.messages.single.todoSteps.single.id, 'task-1');

      await storage.deleteAiChat('chat-1');
      expect(await storage.loadAiChats(), isEmpty);
    },
  );

  test('stores agent metrics in Drift with latest 200 retention', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
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

    storage.dispose();
    final restarted = StorageService(database: database);
    addTearDown(restarted.dispose);
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

  test('migrates terminal history and playbooks from legacy JSON', () async {
    final now = DateTime.utc(2026, 6, 21, 2);
    final terminal = TerminalHistoryRecord(
      sessionId: 'session-1',
      connectionId: 'server-1',
      connectionName: 'Prod',
      displayName: 'Prod shell',
      tmuxSessionName: 'tmux-prod',
      state: 'disconnected',
      errorMessage: null,
      createdAt: now,
      updatedAt: now,
    );
    final playbook = Playbook(
      id: 'playbook-1',
      name: 'Restart',
      description: 'Restart service',
      steps: [
        PlaybookStep(
          id: 'step-1',
          name: 'Restart',
          command: 'systemctl restart nginx',
          description: 'Restart nginx',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
    SharedPreferences.setMockInitialValues({
      'terminal_history_records': jsonEncode([terminal.toJson()]),
      'custom_playbooks': jsonEncode([playbook.toJson()]),
    });

    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    expect(
      (await storage.loadTerminalHistoryRecords()).single.sessionId,
      'session-1',
    );
    expect(
      (await storage.loadPlaybooks()).single.steps.single.command,
      'systemctl restart nginx',
    );
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

    storage.dispose();
    final restarted = StorageService(database: database);
    addTearDown(restarted.dispose);
    await restarted.init();

    final loaded = (await restarted.loadPlaybooks()).single;
    expect(loaded.steps.single.command, contains(secret));
    expect(loaded.steps.single.stdout, contains(secret));
    expect(loaded.steps.single.stderr, contains(secret));
  });

  test('loads legacy plaintext Drift AI chat and Playbook rows', () async {
    const aiSecret = 'LEGACY_AI_MARKER_20260621';
    const playbookSecret = 'LEGACY_PLAYBOOK_MARKER_20260621';
    final now = DateTime.utc(2026, 6, 21, 5);
    final millis = now.millisecondsSinceEpoch;
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    await database.migrationMetaDao.markComplete('drift_ai_chats_migrated_v1');
    await database.migrationMetaDao.markComplete('drift_playbooks_migrated_v1');
    await database.aiChatDao.saveChat(
      db.AiChatsCompanion(
        id: const drift.Value('legacy-chat'),
        title: const drift.Value('Legacy'),
        model: const drift.Value('model-a'),
        createdAt: drift.Value(millis),
        updatedAt: drift.Value(millis),
      ),
      [
        db.AiChatMessagesCompanion(
          id: const drift.Value('legacy-message'),
          chatId: const drift.Value('legacy-chat'),
          role: const drift.Value('assistant'),
          textContent: const drift.Value('plaintext $aiSecret'),
          contextText: const drift.Value<String?>('context $aiSecret'),
          createdAt: drift.Value(millis),
          attachmentsJson: const drift.Value('[]'),
          tracesJson: const drift.Value('[]'),
          todoStepsJson: const drift.Value('[]'),
        ),
      ],
    );
    await database.playbookDao.savePlaybook(
      db.PlaybooksCompanion(
        id: const drift.Value('legacy-playbook'),
        name: const drift.Value('Legacy playbook'),
        description: const drift.Value('Plaintext row'),
        contentJson: drift.Value(
          jsonEncode(
            Playbook(
              id: 'legacy-playbook',
              name: 'Legacy playbook',
              description: 'Plaintext row',
              steps: [
                PlaybookStep(
                  id: 'legacy-step',
                  name: 'Echo',
                  command: 'echo $playbookSecret',
                  description: 'Plaintext command',
                ),
              ],
              createdAt: now,
              updatedAt: now,
            ).toJson(),
          ),
        ),
        createdAt: drift.Value(millis),
        updatedAt: drift.Value(millis),
      ),
    );

    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    expect(
      (await storage.loadAiChats()).single.messages.single.text,
      contains(aiSecret),
    );
    expect(
      (await storage.loadPlaybooks()).single.steps.single.command,
      contains(playbookSecret),
    );
  });

  test(
    're-encrypts legacy plaintext Drift sensitive fields on startup',
    () async {
      const secret = 'LEGACY_PLAINTEXT_MARKER_20260621';
      final now = DateTime.utc(2026, 6, 21, 8);
      final millis = now.millisecondsSinceEpoch;
      final database = db.AppDatabase.forTesting();
      addTearDown(database.close);
      await database.migrationMetaDao.markComplete(
        'drift_ai_chats_migrated_v1',
      );
      await database.migrationMetaDao.markComplete(
        'drift_playbooks_migrated_v1',
      );

      await database.aiChatDao.saveChat(
        db.AiChatsCompanion(
          id: const drift.Value('legacy-plaintext-chat'),
          title: const drift.Value('Legacy plaintext'),
          model: const drift.Value('model-a'),
          createdAt: drift.Value(millis),
          updatedAt: drift.Value(millis),
        ),
        [
          db.AiChatMessagesCompanion(
            id: const drift.Value('legacy-plaintext-message'),
            chatId: const drift.Value('legacy-plaintext-chat'),
            role: const drift.Value('assistant'),
            textContent: const drift.Value('text $secret'),
            contextText: const drift.Value<String?>('context $secret'),
            createdAt: drift.Value(millis),
            attachmentsJson: drift.Value(
              jsonEncode([
                {
                  'fileName': 'secret.txt',
                  'mimeType': 'text/plain',
                  'sizeBytes': secret.length,
                  'dataBase64': base64Encode(utf8.encode(secret)),
                },
              ]),
            ),
            tracesJson: drift.Value(
              jsonEncode([
                {
                  'id': 'trace-secret',
                  'kind': 'tool',
                  'title': 'Trace',
                  'content': 'trace $secret',
                  'createdAt': now.toIso8601String(),
                },
              ]),
            ),
            todoStepsJson: drift.Value(
              jsonEncode([
                {
                  'id': 'step-secret',
                  'name': 'Step',
                  'command': 'echo $secret',
                  'description': 'desc',
                  'status': 'pending',
                  'stdout': 'stdout $secret',
                  'stderr': 'stderr $secret',
                },
              ]),
            ),
          ),
        ],
      );
      await database.playbookDao.savePlaybook(
        db.PlaybooksCompanion(
          id: const drift.Value('legacy-plaintext-playbook'),
          name: const drift.Value('Legacy Playbook'),
          description: const drift.Value('Plaintext'),
          contentJson: drift.Value(
            jsonEncode(
              Playbook(
                id: 'legacy-plaintext-playbook',
                name: 'Legacy Playbook',
                description: 'Plaintext',
                steps: [
                  PlaybookStep(
                    id: 'step-1',
                    name: 'Run',
                    command: 'echo $secret',
                    description: 'desc',
                  ),
                ],
                createdAt: now,
                updatedAt: now,
              ).toJson(),
            ),
          ),
          createdAt: drift.Value(millis),
          updatedAt: drift.Value(millis),
        ),
      );

      final storage = StorageService(database: database);
      addTearDown(storage.dispose);
      await storage.init();

      final reencryptLog = AppLogService.instance.entries.firstWhere(
        (entry) => entry.message == 'Drift sensitive fields re-encrypted',
      );
      expect(reencryptLog.details, contains('aiMessages=1'));
      expect(reencryptLog.details, contains('playbooks=1'));
      expect(reencryptLog.details, isNot(contains(secret)));

      final rawMessage = await database
          .customSelect(
            'SELECT text, context_text, attachments_json, traces_json, '
            'todo_steps_json FROM ai_chat_messages '
            "WHERE id = 'legacy-plaintext-message'",
          )
          .getSingle();
      expect(rawMessage.read<String>('text'), isNot(contains(secret)));
      expect(rawMessage.read<String>('context_text'), isNot(contains(secret)));
      expect(
        rawMessage.read<String>('attachments_json'),
        isNot(contains(secret)),
      );
      expect(rawMessage.read<String>('traces_json'), isNot(contains(secret)));
      expect(
        rawMessage.read<String>('todo_steps_json'),
        isNot(contains(secret)),
      );

      final rawPlaybook = await database
          .customSelect(
            "SELECT content_json FROM playbooks "
            "WHERE id = 'legacy-plaintext-playbook'",
          )
          .getSingle();
      expect(rawPlaybook.read<String>('content_json'), isNot(contains(secret)));

      final loadedChat = (await storage.loadAiChats()).single.messages.single;
      expect(loadedChat.text, contains(secret));
      expect(loadedChat.contextText, contains(secret));
      expect(
        loadedChat.attachments.single.dataBase64,
        base64Encode(utf8.encode(secret)),
      );
      expect(loadedChat.traces.single.content, contains(secret));
      expect(loadedChat.todoSteps.single.stdout, contains(secret));
      expect(loadedChat.todoSteps.single.stderr, contains(secret));

      final loadedPlaybook = (await storage.loadPlaybooks()).single;
      expect(loadedPlaybook.steps.single.command, contains(secret));
      expect(
        await database.migrationMetaDao.isComplete(
          'drift_sensitive_fields_encrypted_v1',
        ),
        isTrue,
      );
    },
  );

  _registerDriftMigrationTests();
}

void _expectNoMarkers(String value, List<String> markers) {
  for (final marker in markers) {
    expect(value, isNot(contains(marker)));
  }
}
