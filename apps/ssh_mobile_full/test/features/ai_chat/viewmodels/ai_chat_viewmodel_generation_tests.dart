part of 'ai_chat_viewmodel_test.dart';

void _registerAiChatViewModelGenerationTests() {
  test(
    'editing a historical user message rebuilds context and clears stale approval',
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
      addTearDown(viewModel.dispose);
      await viewModel.loadInitialDraft();

      final originalUserAt = DateTime.utc(2026, 8, 1, 10);
      final approvedAssistantAt = DateTime.utc(2026, 8, 1, 10, 1);
      final active = viewModel.activeChat!;
      await viewModel.updateActiveChat(
        active.copyWith(
          approvedPlan: AiApprovedPlanRef(
            assistantCreatedAt: approvedAssistantAt,
            approvedAt: approvedAssistantAt,
          ),
          messages: [
            AiChatMessageRecord(
              role: 'user',
              text: 'delete /var/www/test',
              contextText:
                  'Target servers: production\nUser request:\ndelete /var/www/test',
              createdAt: originalUserAt,
            ),
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Plan ready',
              createdAt: approvedAssistantAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Delete data',
                  command: 'rm -rf /var/www/test',
                  description: 'Delete the old test data',
                ),
              ],
            ),
          ],
        ),
      );

      await viewModel.editUserMessage(0, 'inspect /var/www/test');

      final edited = viewModel.activeChat!.messages.firstWhere(
        (message) => message.role == 'user',
      );
      expect(edited.text, 'inspect /var/www/test');
      expect(edited.contextText, contains('inspect /var/www/test'));
      expect(edited.contextText, isNot(contains('delete /var/www/test')));
      expect(viewModel.activeChat!.approvedPlan, isNull);
      expect((await storageService.loadAiChats()).single.approvedPlan, isNull);
      expect(
        viewModel.activeChat!.messages.where(
          (message) => message.role == 'assistant',
        ),
        hasLength(1),
      );
      expect(factory.lastRequestMessages, isNotNull);
      final requestText = factory.lastRequestMessages!
          .map((message) => '${message['content']}')
          .join('\n');
      expect(requestText, contains('inspect /var/www/test'));
      expect(requestText, isNot(contains('delete /var/www/test')));
    },
  );

  test(
    'regenerating history clears an approval tied to the rewritten branch',
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
      addTearDown(viewModel.dispose);
      await viewModel.loadInitialDraft();

      final assistantAt = DateTime.utc(2026, 8, 1, 11);
      final active = viewModel.activeChat!;
      await viewModel.updateActiveChat(
        active.copyWith(
          approvedPlan: AiApprovedPlanRef(
            assistantCreatedAt: assistantAt,
            approvedAt: assistantAt,
          ),
          messages: [
            AiChatMessageRecord(
              role: 'user',
              text: 'inspect service',
              createdAt: assistantAt.subtract(const Duration(minutes: 1)),
            ),
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Plan ready',
              createdAt: assistantAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Inspect service',
                  command: 'systemctl status nginx',
                  description: 'Read the service status',
                ),
              ],
            ),
          ],
        ),
      );

      await viewModel.regenerateAssistant(1);

      expect(viewModel.activeChat!.approvedPlan, isNull);
      expect((await storageService.loadAiChats()).single.approvedPlan, isNull);
    },
  );

  test(
    'close cancels and joins generation before releasing Route state',
    () async {
      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );
      final factory = CancellationGatedRuntimeFactory(
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

      expect(
        await viewModel.sendText(text: 'private generation input'),
        isA<SendTextSuccess>(),
      );
      await factory.streamStarted.future;
      await viewModel.close().timeout(const Duration(seconds: 2));

      final stored = (await storageService.loadAiChats()).single;
      expect(stored.messages.last.role, 'assistant');
      expect(stored.messages.last.text, isEmpty);
      expect(stored.title, isNot(contains('private generation input')));
      viewModel.dispose();
    },
  );

  test(
    'normal return with missing outcome stays unknown and records failure',
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
        finalOutcome: '',
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
      final result = await viewModel.sendText(text: 'inspect missing result');
      expect(result, isA<SendTextSuccess>());
      await waitUntil(
        () => viewModel.sending == false,
        description: 'unknown outcome generation finishes',
      );

      final assistant = viewModel.activeChat!.messages.lastWhere(
        (message) => message.role == 'assistant',
      );
      final summary = assistant.traces.lastWhere(
        (trace) => trace.kind == 'agent_run_summary',
      );
      expect(jsonDecode(summary.content)['finalOutcome'], 'unknown');

      var metrics = await storageService.loadAgentRunMetrics();
      for (var attempt = 0; metrics.isEmpty && attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        metrics = await storageService.loadAgentRunMetrics();
      }
      expect(metrics, isNotEmpty);
      expect(metrics.first.success, isFalse);
    },
  );

  test(
    'approvePlanAndExecute blocks when runtime health is blocking',
    () async {
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        clientHealthAdvisor: const FakeHealthAdvisor(
          ClientRuntimeHealthStatus.blocking,
        ),
      );

      await viewModel.loadInitialDraft();
      final assistantCreatedAt = DateTime.now();
      await viewModel.updateActiveChat(
        viewModel.activeChat!.copyWith(
          planMode: false,
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: assistantCreatedAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Check service',
                  command: 'systemctl status nginx',
                  description: 'Check service status',
                ),
              ],
            ),
          ],
        ),
      );

      final result = await viewModel.approvePlanAndExecute(assistantCreatedAt);

      expect(result, isA<ApprovePlanExecutionBlocked>());
      expect(viewModel.activeChat!.planMode, isFalse);
      expect(viewModel.activeChat!.approvedPlan, isNull);
      expect(viewModel.sending, isFalse);
    },
  );

  test(
    'approvePlanAndExecute warning requires explicit force to continue',
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
        clientHealthAdvisor: const FakeHealthAdvisor(
          ClientRuntimeHealthStatus.warning,
        ),
      );

      await viewModel.loadInitialDraft();
      final assistantCreatedAt = DateTime.now();
      await viewModel.updateActiveChat(
        viewModel.activeChat!.copyWith(
          planMode: false,
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: assistantCreatedAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Check service',
                  command: 'systemctl status nginx',
                  description: 'Check service status',
                ),
              ],
            ),
          ],
        ),
      );

      final warning = await viewModel.approvePlanAndExecute(assistantCreatedAt);
      expect(warning, isA<ApprovePlanExecutionWarning>());
      expect(viewModel.activeChat!.approvedPlan, isNull);

      final started = await viewModel.approvePlanAndExecute(
        assistantCreatedAt,
        forceAfterWarning: true,
      );
      expect(started, isA<ApprovePlanExecutionStarted>());

      await waitUntil(
        () => viewModel.sending == false,
        description: 'forced warning execution finishes',
      );
      expect(viewModel.activeChat!.approvedPlan, isNotNull);
      expect(
        viewModel.activeChat!.messages.any(
          (message) => message.role == 'user' && message.text.contains('执行'),
        ),
        isTrue,
      );
    },
  );

  test(
    'forced warning continuation keeps the original approval inputs',
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
      );
      final healthAdvisor = _GatedHealthAdvisor(
        ClientRuntimeHealthStatus.warning,
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
        clientHealthAdvisor: healthAdvisor,
      );

      await viewModel.loadInitialDraft();
      final assistantCreatedAt = DateTime.now();
      await viewModel.updateActiveChat(
        viewModel.activeChat!.copyWith(
          planMode: false,
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: assistantCreatedAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Check service',
                  command: 'systemctl status nginx',
                  description: 'Check service status',
                ),
              ],
            ),
          ],
        ),
      );
      viewModel.updateSelectedConnections({'server-a'});
      viewModel.updateAllowedTools(viewModel.activeChatId!, {'tool-a'});

      final firstApproval = viewModel.approvePlanAndExecute(assistantCreatedAt);
      await healthAdvisor.started;
      const nextMessageAttachment = AiChatAttachment(
        fileName: 'next-message.txt',
        mimeType: 'text/plain',
        sizeBytes: 4,
        dataBase64: 'bmV4dA==',
      );
      viewModel.addAttachment(nextMessageAttachment);
      viewModel.updateSelectedConnections({'server-b'});
      viewModel.updateAllowedTools(viewModel.activeChatId!, {'tool-b'});
      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api-b.example.com',
        model: 'model-b',
        apiKey: 'key-b',
      );
      healthAdvisor.release();

      expect(await firstApproval, isA<ApprovePlanExecutionWarning>());
      final forcedApproval = await viewModel.approvePlanAndExecute(
        assistantCreatedAt,
        forceAfterWarning: true,
      );
      expect(forcedApproval, isA<ApprovePlanExecutionStarted>());
      final executionMessage = viewModel.activeChat!.messages.lastWhere(
        (message) => message.role == 'user',
      );
      expect(executionMessage.attachments, isEmpty);
      expect(viewModel.pendingAttachments, [same(nextMessageAttachment)]);
      await waitUntil(
        () => viewModel.sending == false,
        description: 'forced warning execution finishes',
      );
      expect(factory.lastSelectedConnectionIds, {'server-a'});
      expect(factory.lastAllowedTools, {'tool-a'});
      expect(factory.lastSettings?.baseUrl, 'https://api.example.com');
      expect(factory.lastSettings?.model, 'demo-model');
      expect(viewModel.selectedConnectionIds, {'server-b'});
    },
  );

  test(
    'plan approval snapshots mutable turn inputs during health check',
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
      );
      final healthAdvisor = _GatedHealthAdvisor();
      final viewModel = createAiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        runtimeFactory: factory,
        clientHealthAdvisor: healthAdvisor,
      );

      await viewModel.loadInitialDraft();
      final assistantCreatedAt = DateTime.now();
      await viewModel.updateActiveChat(
        viewModel.activeChat!.copyWith(
          planMode: false,
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: assistantCreatedAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Check service',
                  command: 'systemctl status nginx',
                  description: 'Check service status',
                ),
              ],
            ),
          ],
        ),
      );
      viewModel.updateSelectedConnections({'server-a'});
      viewModel.updateAllowedTools(viewModel.activeChatId!, {'tool-a'});

      final approval = viewModel.approvePlanAndExecute(assistantCreatedAt);
      await healthAdvisor.started;
      const nextMessageAttachment = AiChatAttachment(
        fileName: 'next-message.txt',
        mimeType: 'text/plain',
        sizeBytes: 4,
        dataBase64: 'bmV4dA==',
      );
      viewModel.addAttachment(nextMessageAttachment);
      viewModel.updateSelectedConnections({'server-b'});
      viewModel.updateAllowedTools(viewModel.activeChatId!, {'tool-b'});
      healthAdvisor.release();

      expect(await approval, isA<ApprovePlanExecutionStarted>());
      final executionMessage = viewModel.activeChat!.messages.lastWhere(
        (message) => message.role == 'user',
      );
      expect(executionMessage.attachments, isEmpty);
      expect(viewModel.pendingAttachments, [same(nextMessageAttachment)]);
      await waitUntil(
        () => viewModel.sending == false,
        description: 'approved execution finishes',
      );
      expect(factory.lastSelectedConnectionIds, {'server-a'});
      expect(factory.lastAllowedTools, {'tool-a'});
      expect(viewModel.selectedConnectionIds, {'server-b'});
    },
  );

  test(
    'generate assistant response failure with empty partialAnswer assigns agentRunId to error message',
    () async {
      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );

      final factory = FakeFailureRuntimeFactory(
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
      final result = await viewModel.sendText(text: 'hello');
      expect(result, isA<SendTextSuccess>());

      // Wait for async runner execution
      await waitUntil(
        () =>
            viewModel.activeChat?.messages.any((m) => m.role == 'error') ==
            true,
        description: 'error message after failed generation',
      );
      await waitUntil(
        () => viewModel.sending == false,
        description: 'generation finishes after failure',
      );

      final messages = viewModel.activeChat!.messages;
      expect(messages, isNotEmpty);
      final errorMessage = messages.firstWhere((m) => m.role == 'error');
      expect(errorMessage.agentRunId, isNotNull);
      expect(errorMessage.agentRunId, isNotEmpty);
      expect(errorMessage.traces, hasLength(1));
      expect(errorMessage.traces.single.kind, 'agent_run_summary');
      expect(
        jsonDecode(errorMessage.traces.single.content)['finalOutcome'],
        'modelError',
      );
    },
  );

  test('Plan Mode transition is atomic and clears old approval', () async {
    final viewModel = createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
    );
    addTearDown(viewModel.dispose);
    await viewModel.loadInitialDraft();
    final active = viewModel.activeChat!;
    final approvedAt = DateTime.utc(2026, 7, 13, 12);
    await viewModel.updateActiveChat(
      active.copyWith(
        approvedPlan: AiApprovedPlanRef(
          assistantCreatedAt: approvedAt,
          approvedAt: approvedAt,
        ),
      ),
    );

    final result = await viewModel.setPlanModeForActiveChat(
      chatId: active.id,
      enabled: true,
    );

    expect(result, SetPlanModeResult.updated);
    expect(viewModel.activeChat!.planMode, isTrue);
    expect(viewModel.activeChat!.approvedPlan, isNull);
    final persisted = (await storageService.loadAiChats()).singleWhere(
      (chat) => chat.id == active.id,
    );
    expect(persisted.planMode, isTrue);
    expect(persisted.approvedPlan, isNull);
  });

  test('failed Plan Mode transition preserves memory and storage', () async {
    final failingStorage = _FailPlanModeSaveStorage();
    await failingStorage.init();
    attachTestAiRepository(failingStorage);
    addTearDown(failingStorage.dispose);
    final failingSsh = createTestSshService(failingStorage);
    final failingSftp = createTestSftpService(failingStorage);
    final failingMonitor = createTestPerformanceMonitorService(
      failingSsh,
      failingStorage,
    );
    final failingPlaybooks = createTestPlaybook(
      repository: failingStorage.playbookRepository,
      sshService: failingSsh,
    );
    final failingRag = await createTestRagService(failingStorage);
    final viewModel = createAiChatViewModel(
      storageService: failingStorage,
      sshService: failingSsh,
      sftpService: failingSftp,
      performanceMonitorService: failingMonitor,
      playbookService: failingPlaybooks,
      ragService: failingRag,
      appSettings: appSettings,
    );
    addTearDown(viewModel.dispose);
    await viewModel.loadInitialDraft();
    final active = viewModel.activeChat!;
    await failingStorage.saveAiChat(active);
    failingStorage.failNextAiChatSave = true;

    final result = await viewModel.setPlanModeForActiveChat(
      chatId: active.id,
      enabled: true,
    );

    expect(result, SetPlanModeResult.failed);
    expect(viewModel.activeChat!.planMode, isFalse);
    expect(viewModel.activeChat!.approvedPlan, active.approvedPlan);
    final persisted = (await failingStorage.loadAiChats()).singleWhere(
      (chat) => chat.id == active.id,
    );
    expect(persisted.planMode, isFalse);
    expect(persisted.approvedPlan, active.approvedPlan);

    expect(
      await viewModel.setPlanModeForActiveChat(
        chatId: active.id,
        enabled: true,
      ),
      SetPlanModeResult.updated,
    );
    expect(viewModel.activeChat!.planMode, isTrue);
  });
}
