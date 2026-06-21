import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart' as db;
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('AppDatabase opens in tests', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);

    final result = await database.customSelect('SELECT 1 AS value').getSingle();

    expect(result.read<int>('value'), 1);
  });

  test('migrates legacy AI chats to Drift and preserves message payloads',
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
    expect(loaded.single.approvedPlan?.approvedAt,
        now.add(const Duration(minutes: 1)));
    expect(
        loaded.single.messages.single.attachments.single.fileName, 'notes.txt');
    expect(loaded.single.messages.single.traces.single.id, 'trace-1');
    expect(loaded.single.messages.single.todoSteps.single.id, 'task-1');

    await storage.deleteAiChat('chat-1');
    expect(await storage.loadAiChats(), isEmpty);
  });

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
    expect(loaded.attachments.single.dataBase64,
        base64Encode(utf8.encode(secret)));
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

    expect((await storage.loadTerminalHistoryRecords()).single.sessionId,
        'session-1');
    expect((await storage.loadPlaybooks()).single.steps.single.command,
        'systemctl restart nginx');
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
    await database.migrationMetaDao.markComplete(
      'drift_ai_chats_migrated_v1',
    );
    await database.migrationMetaDao.markComplete(
      'drift_playbooks_migrated_v1',
    );
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
        contentJson: drift.Value(jsonEncode(
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
        )),
        createdAt: drift.Value(millis),
        updatedAt: drift.Value(millis),
      ),
    );

    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    expect((await storage.loadAiChats()).single.messages.single.text,
        contains(aiSecret));
    expect((await storage.loadPlaybooks()).single.steps.single.command,
        contains(playbookSecret));
  });

  test('backup import persists AgentRunMetrics into Drift across restart',
      () async {
    final now = DateTime.utc(2026, 6, 21, 6);
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    await storage.init();
    final metric = AgentRunMetrics(
      id: 'imported-metric',
      startedAt: now,
      finishedAt: now.add(const Duration(seconds: 4)),
      model: 'model-a',
      promptTokens: 1,
      completionTokens: 2,
      totalTokens: 3,
      elapsedMs: 4,
    );
    await storage.importAppDataJson(jsonEncode({
      'format': 'ssh_mobile_backup',
      'version': 2,
      'connections': const [],
      'agentRunMetrics': [metric.toJson()],
    }));
    storage.dispose();

    final restarted = StorageService(database: database);
    addTearDown(restarted.dispose);
    await restarted.init();

    final metrics = await restarted.loadAgentRunMetrics();
    expect(metrics.single.id, 'imported-metric');
  });

  test('enforces AI chat retention in Drift and cascades messages', () async {
    final base = DateTime.utc(2026, 6, 21, 7);
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    for (var i = 0; i < 85; i++) {
      final time = base.add(Duration(minutes: i));
      await storage.saveAiChat(
        AiChatRecord(
          id: 'chat-$i',
          title: 'Chat $i',
          model: 'model-a',
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'message $i',
              createdAt: time,
            ),
          ],
          createdAt: time,
          updatedAt: time,
        ),
      );
    }

    final chatCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM ai_chats')
        .getSingle();
    final messageCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM ai_chat_messages')
        .getSingle();
    expect(chatCount.read<int>('count'), 80);
    expect(messageCount.read<int>('count'), 80);

    final loaded = await storage.loadAiChats();
    expect(loaded, hasLength(80));
    expect(loaded.first.id, 'chat-84');
    expect(loaded.last.id, 'chat-5');
  });

  test('SFTP history reads gracefully when Drift is inactive', () async {
    final storage = StorageService();

    await storage.recordVisitedPath('server-1', '/var/log');

    expect(await storage.loadRecentPaths('server-1'), isEmpty);
    expect(await storage.loadFavoritePaths('server-1'), isEmpty);
    expect(await storage.findFavoritePath('server-1', '/var/log'), isNull);
  });

  test('backup exports and imports Drift SFTP path history without secrets',
      () async {
    final database = db.AppDatabase.forTesting();
    final storage = StorageService(database: database);
    await storage.init();
    await storage.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: 'Prod',
        host: 'prod.example.com',
        username: 'root',
        password: 'server-secret',
        privateKey: 'private-key',
        authMethod: AuthMethod.both,
      ),
    );
    await storage.recordVisitedPath('server-1', '/var/log');
    await storage.addFavoritePath('server-1', '/etc/nginx', 'nginx');

    final backup = await storage.exportAppDataJson();
    expect(backup, isNot(contains('server-secret')));
    expect(backup, isNot(contains('private-key')));

    final decoded = jsonDecode(backup) as Map<String, dynamic>;
    expect(decoded['sftpRecentPaths'], isNotEmpty);
    expect(decoded['sftpFavoritePaths'], isNotEmpty);

    storage.dispose();
    await database.close();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final importedDatabase = db.AppDatabase.forTesting();
    addTearDown(importedDatabase.close);
    final imported = StorageService(database: importedDatabase);
    addTearDown(imported.dispose);
    await imported.init();
    await imported.importAppDataJson(backup);

    expect(
        (await imported.loadRecentPaths('server-1')).single.path, '/var/log');
    expect((await imported.loadFavoritePaths('server-1')).single.name, 'nginx');
    expect(await imported.getPassword('server-1'), isNull);
  });
}
