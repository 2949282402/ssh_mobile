part of 'ai_chat_viewmodel_test.dart';

void _registerAiChatViewModelCoreTests() {
  test('loadInitialDraft loads a draft and updates state', () async {
    final viewModel = createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
    );

    expect(viewModel.loading, isTrue);
    expect(viewModel.chats, isEmpty);
    expect(viewModel.activeChatId, isNull);

    await viewModel.loadInitialDraft();

    expect(viewModel.loading, isFalse);
    expect(viewModel.chats, hasLength(1));
    expect(viewModel.activeChatId, isNotNull);
    expect(viewModel.activeChat!.messages, isEmpty);
  });

  test('loadInitialDraft exposes failure and retry can recover', () async {
    final retryStorage = _FailOnceInitialSettingsStorage();
    await retryStorage.init();
    addTearDown(retryStorage.dispose);
    final retrySsh = createTestSshService(retryStorage);
    final retrySftp = createTestSftpService(retryStorage);
    final retryMonitor = createTestPerformanceMonitorService(
      retrySsh,
      retryStorage,
    );
    final retryPlaybooks = PlaybookService(
      repository: retryStorage.playbookRepository,
      sshService: retrySsh,
    );
    final retryRag = RagService(aiStorage: retryStorage.aiStorage);
    final viewModel = createAiChatViewModel(
      storageService: retryStorage,
      sshService: retrySsh,
      sftpService: retrySftp,
      performanceMonitorService: retryMonitor,
      playbookService: retryPlaybooks,
      ragService: retryRag,
      appSettings: appSettings,
    );
    addTearDown(viewModel.dispose);

    await viewModel.loadInitialDraft();
    expect(viewModel.loading, isFalse);
    expect(viewModel.initialDraftFailed, isTrue);
    expect(viewModel.activeChat, isNull);
    expect(retryStorage.settingsLoadAttempts, 1);

    await viewModel.retryInitialDraft();
    expect(viewModel.loading, isFalse);
    expect(viewModel.initialDraftFailed, isFalse);
    expect(viewModel.activeChat, isNotNull);
    expect(retryStorage.settingsLoadAttempts, 2);
  });

  test('sendText returns SendTextEmptyText for empty text', () async {
    final viewModel = createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
    );

    await viewModel.loadInitialDraft();

    final result = await viewModel.sendText(text: '');
    expect(result, isA<SendTextEmptyText>());
  });

  test(
    'sendText returns SendTextApiKeyMissing if api key is missing',
    () async {
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();

      final result = await viewModel.sendText(text: 'hello');
      expect(result, isA<SendTextApiKeyMissing>());
    },
  );

  test('addAttachment and removeAttachment works correctly', () async {
    final viewModel = createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
    );

    await viewModel.loadInitialDraft();

    expect(viewModel.pendingAttachments, isEmpty);

    final attachment = const AiChatAttachment(
      fileName: 'test.png',
      mimeType: 'image/png',
      sizeBytes: 100,
      dataBase64: 'abc',
    );

    viewModel.addAttachment(attachment);
    expect(viewModel.pendingAttachments, hasLength(1));
    expect(viewModel.pendingAttachments.first.fileName, 'test.png');

    viewModel.removeAttachmentAt(0);
    expect(viewModel.pendingAttachments, isEmpty);
  });

  test('deleteChat fallback to new draft if list is empty', () async {
    final viewModel = createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
    );

    await viewModel.loadInitialDraft();
    final originalId = viewModel.activeChatId!;

    await Future.delayed(const Duration(milliseconds: 1));

    await viewModel.deleteChat(originalId);

    expect(viewModel.chats, hasLength(1));
    expect(viewModel.activeChatId, isNot(originalId));
  });

  test('updateAllowedTools updates tools correctly', () async {
    final viewModel = createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
    );

    await viewModel.loadInitialDraft();
    final activeChatId = viewModel.activeChatId!;

    viewModel.updateAllowedTools(activeChatId, {'tool1', 'tool2'});
    // Internally stored, let's verify that we can execute sendText slash command for /tools and check result
    final result = await viewModel.sendText(text: '/tools');
    expect(result, isA<SendTextSlashCommandOpenToolsSelector>());
    final openSelector = result as SendTextSlashCommandOpenToolsSelector;
    expect(openSelector.currentAllowedTools, containsAll(['tool1', 'tool2']));
  });

  test('getConnection and connections returns expected values', () async {
    final viewModel = createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
    );

    expect(viewModel.connections, isEmpty);
    expect(viewModel.getConnection('non_existent'), isNull);
  });

  test(
    'checkPendingDiagnosticPrompt retrieves and clears pending prompt',
    () async {
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      playbookService.pendingDiagnosticPrompt = 'diagnose_me';
      expect(viewModel.checkPendingDiagnosticPrompt(), 'diagnose_me');
      expect(playbookService.pendingDiagnosticPrompt, isNull);
      expect(viewModel.checkPendingDiagnosticPrompt(), isNull);
    },
  );

  test(
    'loadLlmSettingsData and logLlmSettingsOpened works without errors',
    () async {
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final data = await viewModel.loadLlmSettingsData();
      expect(data, isNotNull);
      expect(data['settings'], isNotNull);

      // Verify that calling logLlmSettingsOpened runs without throwing
      final settings = data['settings'] as AiConnectionSettings;
      expect(() => viewModel.logLlmSettingsOpened(settings), returnsNormally);
    },
  );

  test(
    '/plan alone enables Plan Mode and returns slash-command handled feedback',
    () async {
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();
      expect(viewModel.activeChat!.planMode, isFalse);

      final result = await viewModel.sendText(text: '/plan');
      expect(result, isA<SendTextSlashCommandHandled>());
      expect(viewModel.activeChat!.planMode, isTrue);
    },
  );

  test(
    '/plan <args> enables Plan Mode and proceeds into the normal send flow',
    () async {
      final factory = FakeSuccessRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        runtimeFactory: factory,
      );

      await viewModel.loadInitialDraft();
      expect(viewModel.activeChat!.planMode, isFalse);

      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api-a.example.com',
        model: 'model-a',
        apiKey: 'key-a',
      );

      final result = await viewModel.sendText(text: '/plan diagnose nginx');
      expect(result, isA<SendTextSuccess>());
      expect(viewModel.activeChat!.planMode, isTrue);

      // Wait for generation to finish to avoid unawaited async leaks
      await waitUntil(
        () => viewModel.sending == false,
        description: 'generation finishes',
      );

      final messages = viewModel.activeChat!.messages;
      final userMessage = messages.firstWhere((m) => m.role == 'user');
      expect(userMessage.text, equals('diagnose nginx'));
    },
  );

  test(
    '/plan snapshots turn inputs before its mode persistence await',
    () async {
      final recordingRag = _RecordingTurnRagService(
        aiStorage: storageService.aiStorage,
      );
      final factory = FakeSuccessRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: recordingRag,
        appSettings: appSettings,
      );
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        runtimeFactory: factory,
      );
      await viewModel.loadInitialDraft();
      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api-a.example.com',
        model: 'model-a',
        apiKey: 'key-a',
      );
      await storageService.saveAliyunApiKey('rag-key-a');
      await storageService.addConnection(
        ConnectionConfig(
          id: 'server-a',
          name: 'Server A',
          host: 'old.example.com',
          username: 'ops',
        ),
      );
      await appSettings.setRagEnabled(true);
      await appSettings.setRagSearchMode('bm25');
      await appSettings.setRagTopN(8);
      const submittedAttachment = AiChatAttachment(
        fileName: 'submitted.txt',
        mimeType: 'text/plain',
        sizeBytes: 1,
        dataBase64: 'YQ==',
      );
      const nextAttachment = AiChatAttachment(
        fileName: 'next.txt',
        mimeType: 'text/plain',
        sizeBytes: 1,
        dataBase64: 'Yg==',
      );
      viewModel.addAttachment(submittedAttachment);
      viewModel.updateSelectedConnections({'server-a'});
      viewModel.updateAllowedTools(viewModel.activeChatId!, {'tool-a'});
      final gatedStorage = storageService as _GateNextChatSaveStorage;
      gatedStorage.gateNextChatSave();

      final send = viewModel.sendText(text: '/plan diagnose nginx');
      await gatedStorage.nextChatSaveStarted;
      viewModel.addAttachment(nextAttachment);
      viewModel.updateSelectedConnections({'server-b'});
      viewModel.updateAllowedTools(viewModel.activeChatId!, {'tool-b'});
      await storageService.updateConnection(
        storageService
            .getConnection('server-a')!
            .copyWith(host: 'replacement.example.com'),
      );
      await appSettings.setRagSearchMode('vector');
      await appSettings.setRagTopN(1);
      await storageService.saveAliyunApiKey('rag-key-b');
      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api-b.example.com',
        model: 'model-b',
        apiKey: 'key-b',
      );
      gatedStorage.releaseChatSave();

      expect(await send, isA<SendTextSuccess>());
      final userMessage = viewModel.activeChat!.messages.lastWhere(
        (message) => message.role == 'user',
      );
      expect(userMessage.attachments, [same(submittedAttachment)]);
      expect(userMessage.contextText, contains('ops@old.example.com:22'));
      expect(
        userMessage.contextText,
        isNot(contains('replacement.example.com')),
      );
      expect(viewModel.pendingAttachments, [same(nextAttachment)]);
      await waitUntil(
        () => viewModel.sending == false,
        description: 'Plan request generation finishes',
      );
      expect(factory.lastSelectedConnectionIds, {'server-a'});
      expect(factory.lastAllowedTools, {'tool-a'});
      expect(factory.lastSettings?.baseUrl, 'https://api-a.example.com');
      expect(factory.lastSettings?.model, 'model-a');
      expect(recordingRag.receivedSearchMode, 'bm25');
      expect(recordingRag.receivedLimit, 8);
      expect(recordingRag.receivedExpectedKey, isTrue);
      expect(viewModel.selectedConnectionIds, {'server-b'});
    },
  );

  test(
    'normal return with blocked outcome embeds reason and records failure',
    () async {
      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );
      final factory = FakeSuccessRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        finalOutcome: 'loopGuardBlocked',
      );
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        runtimeFactory: factory,
      );

      await viewModel.loadInitialDraft();
      final result = await viewModel.sendText(text: 'inspect loop');
      expect(result, isA<SendTextSuccess>());
      await waitUntil(
        () => viewModel.sending == false,
        description: 'blocked outcome generation finishes',
      );

      final assistant = viewModel.activeChat!.messages.lastWhere(
        (message) => message.role == 'assistant',
      );
      final summary = assistant.traces.lastWhere(
        (trace) => trace.kind == 'agent_run_summary',
      );
      expect(jsonDecode(summary.content)['finalOutcome'], 'loopGuardBlocked');

      var metrics = await storageService.loadAgentRunMetrics();
      for (var attempt = 0; metrics.isEmpty && attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        metrics = await storageService.loadAgentRunMetrics();
      }
      expect(metrics, isNotEmpty);
      expect(metrics.first.success, isFalse);
    },
  );
}
