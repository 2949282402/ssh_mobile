part of 'drift_storage_test.dart';

void _registerDriftMigrationTests() {
  test('re-encryption migration is idempotent for encrypted rows', () async {
    const secret = 'IDEMPOTENT_MARKER_20260621';
    final now = DateTime.utc(2026, 6, 21, 9);
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    await storage.init();
    await storage.saveAiChat(
      AiChatRecord(
        id: 'idempotent-chat',
        title: 'Idempotent',
        model: 'model-a',
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'text $secret',
            contextText: 'context $secret',
            traces: [
              AiMessageTrace(
                id: 'trace-idempotent',
                kind: 'tool',
                title: 'Trace',
                content: 'trace $secret',
                createdAt: now,
              ),
            ],
            todoSteps: const [
              AiTodoStep(
                id: 'task-idempotent',
                name: 'Task',
                command: 'echo IDEMPOTENT_MARKER_20260621',
                description: 'Task description',
              ),
            ],
            createdAt: now,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),
    );
    await storage.savePlaybook(
      Playbook(
        id: 'idempotent-playbook',
        name: 'Idempotent playbook',
        description: 'Already encrypted',
        steps: [
          PlaybookStep(
            id: 'step-idempotent',
            name: 'Echo',
            command: 'echo $secret',
            description: 'Print marker',
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final beforeMessage = await database
        .customSelect(
          'SELECT text, context_text, attachments_json, traces_json, '
          'todo_steps_json FROM ai_chat_messages '
          "WHERE id LIKE 'idempotent-chat:%'",
        )
        .getSingle();
    final beforePlaybook = await database
        .customSelect(
          "SELECT content_json FROM playbooks "
          "WHERE id = 'idempotent-playbook'",
        )
        .getSingle();
    await storage.shutdown();
    storage.dispose();
    await database.customStatement(
      "DELETE FROM migration_meta "
      "WHERE key = 'drift_sensitive_fields_encrypted_v1'",
    );

    final restarted = StorageService(database: database);
    addTearDown(() => _shutdownAndDispose(restarted));
    await restarted.init();

    final afterMessage = await database
        .customSelect(
          'SELECT text, context_text, attachments_json, traces_json, '
          'todo_steps_json FROM ai_chat_messages '
          "WHERE id LIKE 'idempotent-chat:%'",
        )
        .getSingle();
    final afterPlaybook = await database
        .customSelect(
          "SELECT content_json FROM playbooks "
          "WHERE id = 'idempotent-playbook'",
        )
        .getSingle();

    for (final column in [
      'text',
      'context_text',
      'attachments_json',
      'traces_json',
      'todo_steps_json',
    ]) {
      expect(
        afterMessage.read<String>(column),
        beforeMessage.read<String>(column),
      );
    }
    expect(
      afterPlaybook.read<String>('content_json'),
      beforePlaybook.read<String>('content_json'),
    );
    expect(
      (await restarted.loadAiChats()).single.messages.single.text,
      contains(secret),
    );
    expect(
      (await restarted.loadPlaybooks()).single.steps.single.command,
      contains(secret),
    );
  });

  test(
    'raw Drift storage does not contain known sensitive markers after normal save and legacy migration',
    () async {
      const markers = [
        'SSH_PASSWORD_MARKER',
        'PRIVATE_KEY_MARKER',
        'API_KEY_MARKER',
        'AI_TRACE_MARKER',
        'TODO_STDOUT_MARKER',
        'PLAYBOOK_COMMAND_MARKER',
      ];
      final now = DateTime.utc(2026, 6, 21, 12);
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
          id: const drift.Value('legacy-marker-chat'),
          title: const drift.Value('Legacy marker'),
          model: const drift.Value('model-a'),
          createdAt: drift.Value(millis),
          updatedAt: drift.Value(millis),
        ),
        [
          db.AiChatMessagesCompanion(
            id: const drift.Value('legacy-marker-message'),
            chatId: const drift.Value('legacy-marker-chat'),
            role: const drift.Value('assistant'),
            textContent: drift.Value('text ${markers[0]}'),
            contextText: drift.Value<String?>('context ${markers[1]}'),
            createdAt: drift.Value(millis),
            attachmentsJson: drift.Value(
              jsonEncode([
                {
                  'fileName': 'attachment-${markers[2]}.txt',
                  'mimeType': 'text/plain',
                  'sizeBytes': markers[2].length,
                  'dataBase64': base64Encode(utf8.encode(markers[2])),
                },
              ]),
            ),
            tracesJson: drift.Value(
              jsonEncode([
                {
                  'id': 'trace-marker',
                  'kind': 'tool',
                  'title': 'Trace',
                  'content': 'trace ${markers[3]}',
                  'createdAt': now.toIso8601String(),
                },
              ]),
            ),
            todoStepsJson: drift.Value(
              jsonEncode([
                {
                  'id': 'todo-marker',
                  'name': 'Todo',
                  'command': 'echo ${markers[4]}',
                  'description': 'desc',
                  'status': 'pending',
                  'stdout': 'stdout ${markers[4]}',
                },
              ]),
            ),
          ),
        ],
      );
      await database.playbookDao.savePlaybook(
        db.PlaybooksCompanion(
          id: const drift.Value('legacy-marker-playbook'),
          name: const drift.Value('Legacy marker playbook'),
          description: const drift.Value('Plaintext marker row'),
          contentJson: drift.Value(
            jsonEncode(
              Playbook(
                id: 'legacy-marker-playbook',
                name: 'Legacy marker playbook',
                description: 'Plaintext marker row',
                steps: [
                  PlaybookStep(
                    id: 'legacy-marker-step',
                    name: 'Run',
                    command: 'echo ${markers[5]}',
                    description: 'desc ${markers[5]}',
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
      addTearDown(() => _shutdownAndDispose(storage));
      await storage.init();
      await storage.saveAiChat(
        AiChatRecord(
          id: 'normal-marker-chat',
          title: 'Normal marker',
          model: 'model-a',
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'text ${markers[0]}',
              contextText: 'context ${markers[1]}',
              attachments: [
                AiChatAttachment(
                  fileName: 'normal-${markers[2]}.txt',
                  mimeType: 'text/plain',
                  sizeBytes: markers[2].length,
                  dataBase64: base64Encode(utf8.encode(markers[2])),
                ),
              ],
              traces: [
                AiMessageTrace(
                  id: 'normal-trace-marker',
                  kind: 'tool',
                  title: 'Trace',
                  content: 'trace ${markers[3]}',
                  createdAt: now,
                ),
              ],
              todoSteps: const [
                AiTodoStep(
                  id: 'normal-todo-marker',
                  name: 'Todo',
                  command: 'echo TODO_STDOUT_MARKER',
                  description: 'desc',
                  stdout: 'stdout TODO_STDOUT_MARKER',
                ),
              ],
              createdAt: now.add(const Duration(minutes: 1)),
            ),
          ],
          createdAt: now.add(const Duration(minutes: 1)),
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
      );
      await storage.savePlaybook(
        Playbook(
          id: 'normal-marker-playbook',
          name: 'Normal marker playbook',
          description: 'Normal save marker row',
          steps: [
            PlaybookStep(
              id: 'normal-marker-step',
              name: 'Run',
              command: 'echo ${markers[5]}',
              description: 'desc ${markers[5]}',
            ),
          ],
          createdAt: now.add(const Duration(minutes: 1)),
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
      );

      final rawMessages = await database
          .customSelect(
            'SELECT text, context_text, attachments_json, traces_json, '
            'todo_steps_json FROM ai_chat_messages',
          )
          .get();
      for (final row in rawMessages) {
        for (final column in [
          'text',
          'context_text',
          'attachments_json',
          'traces_json',
          'todo_steps_json',
        ]) {
          _expectNoMarkers(row.read<String>(column), markers);
        }
      }

      final rawPlaybooks = await database
          .customSelect('SELECT content_json FROM playbooks')
          .get();
      for (final row in rawPlaybooks) {
        _expectNoMarkers(row.read<String>('content_json'), markers);
      }

      final roundtrip = jsonEncode({
        'aiChats': (await storage.loadAiChats())
            .map((chat) => chat.toJson())
            .toList(growable: false),
        'playbooks': (await storage.loadPlaybooks())
            .map((playbook) => playbook.toJson())
            .toList(growable: false),
      });
      for (final marker in markers) {
        expect(roundtrip, contains(marker));
      }
    },
  );

  test(
    'backup import persists AgentRunMetrics into Drift across restart',
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
      await storage.importAppDataJson(
        jsonEncode({
          'format': 'ssh_mobile_backup',
          'version': 2,
          'connections': const [],
          'agentRunMetrics': [metric.toJson()],
        }),
      );
      await storage.shutdown();
      storage.dispose();

      final restarted = StorageService(database: database);
      addTearDown(() => _shutdownAndDispose(restarted));
      await restarted.init();

      final metrics = await restarted.loadAgentRunMetrics();
      expect(metrics.single.id, 'imported-metric');
    },
  );

  test(
    'backup import writes AI chats and playbooks back as encrypted Drift rows',
    () async {
      const marker = 'BACKUP_DRIFT_MARKER_20260621';
      const password = 'backup-server-password';
      const privateKey = 'backup-private-key';
      const apiKey = 'sk-backup-secret';
      final now = DateTime.utc(2026, 6, 21, 13);
      final database = db.AppDatabase.forTesting();
      final storage = StorageService(database: database);
      await storage.init();
      await storage.addConnection(
        ConnectionConfig(
          id: 'backup-server',
          name: 'Backup server',
          host: 'backup.example.com',
          username: 'root',
          password: password,
          privateKey: privateKey,
          authMethod: AuthMethod.both,
        ),
      );
      await storage.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: apiKey,
      );
      await storage.saveAiChat(
        AiChatRecord(
          id: 'backup-chat',
          title: 'Backup chat',
          model: 'model-a',
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'message $marker',
              contextText: 'context $marker',
              traces: [
                AiMessageTrace(
                  id: 'backup-trace',
                  kind: 'tool',
                  title: 'Trace',
                  content: 'trace $marker',
                  createdAt: now,
                ),
              ],
              todoSteps: const [
                AiTodoStep(
                  id: 'backup-step',
                  name: 'Step',
                  command: 'echo BACKUP_DRIFT_MARKER_20260621',
                  description: 'desc',
                  stdout: 'stdout BACKUP_DRIFT_MARKER_20260621',
                ),
              ],
              createdAt: now,
            ),
          ],
          createdAt: now,
          updatedAt: now,
        ),
      );
      await storage.savePlaybook(
        Playbook(
          id: 'backup-playbook',
          name: 'Backup playbook',
          description: 'Backup content',
          steps: [
            PlaybookStep(
              id: 'backup-playbook-step',
              name: 'Run',
              command: 'echo $marker',
              description: 'desc $marker',
            ),
          ],
          createdAt: now,
          updatedAt: now,
        ),
      );

      final backup = await storage.exportAppDataJson();
      expect(backup, contains(marker));
      expect(backup, isNot(contains(password)));
      expect(backup, isNot(contains(privateKey)));
      expect(backup, isNot(contains(apiKey)));
      final decoded = jsonDecode(backup) as Map<String, dynamic>;
      final connection =
          (decoded['connections'] as List<dynamic>).single
              as Map<String, dynamic>;
      final aiSettings = decoded['aiSettings'] as Map<String, dynamic>;
      expect(connection['password'], '');
      expect(connection['privateKey'], '');
      expect(aiSettings['apiKey'], '');

      await storage.shutdown();
      storage.dispose();
      await AppLogService.instance.pendingDbWrites;
      AppLogService.instance.resetDatabaseForTesting();
      await database.close();
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final importedDatabase = db.AppDatabase.forTesting();
      addTearDown(importedDatabase.close);
      final imported = StorageService(database: importedDatabase);
      addTearDown(() => _shutdownAndDispose(imported));
      await imported.init();
      await imported.importAppDataJson(backup);

      final rawMessage = await importedDatabase
          .customSelect(
            'SELECT text, context_text, traces_json, todo_steps_json '
            'FROM ai_chat_messages',
          )
          .getSingle();
      _expectNoMarkers(rawMessage.read<String>('text'), const [marker]);
      _expectNoMarkers(rawMessage.read<String>('context_text'), const [marker]);
      _expectNoMarkers(rawMessage.read<String>('traces_json'), const [marker]);
      _expectNoMarkers(rawMessage.read<String>('todo_steps_json'), const [
        marker,
      ]);
      final rawPlaybook = await importedDatabase
          .customSelect('SELECT content_json FROM playbooks')
          .getSingle();
      _expectNoMarkers(rawPlaybook.read<String>('content_json'), const [
        marker,
      ]);

      final loadedChat = (await imported.loadAiChats()).single;
      final loadedPlaybook = (await imported.loadPlaybooks()).single;
      expect(jsonEncode(loadedChat.toJson()), contains(marker));
      expect(jsonEncode(loadedPlaybook.toJson()), contains(marker));
      expect(await imported.getPassword('backup-server'), isNull);
      expect((await imported.loadAiConnectionSettings()).hasApiKey, isFalse);
    },
  );

  test('enforces AI chat retention in Drift and cascades messages', () async {
    final base = DateTime.utc(2026, 6, 21, 7);
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(() => _shutdownAndDispose(storage));
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

  test(
    'backup exports and imports Drift SFTP path history without secrets',
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

      await storage.shutdown();
      storage.dispose();
      await AppLogService.instance.pendingDbWrites;
      AppLogService.instance.resetDatabaseForTesting();
      await database.close();
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final importedDatabase = db.AppDatabase.forTesting();
      addTearDown(importedDatabase.close);
      final imported = StorageService(database: importedDatabase);
      addTearDown(() => _shutdownAndDispose(imported));
      await imported.init();
      await imported.importAppDataJson(backup);

      expect(
        (await imported.loadRecentPaths('server-1')).single.path,
        '/var/log',
      );
      expect(
        (await imported.loadFavoritePaths('server-1')).single.name,
        'nginx',
      );
      expect(await imported.getPassword('server-1'), isNull);
    },
  );
}

db.AppDatabase _failingDatabase() {
  return db.AppDatabase(
    executor: drift.LazyDatabase(() async {
      throw StateError('forced database open failure');
    }),
  );
}

Future<void> _closeIgnoringErrors(db.AppDatabase database) async {
  try {
    await database.close();
  } catch (_) {
    // The failing database may never open far enough to close cleanly.
  }
}
