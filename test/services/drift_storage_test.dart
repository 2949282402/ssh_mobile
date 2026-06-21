import 'dart:convert';

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
