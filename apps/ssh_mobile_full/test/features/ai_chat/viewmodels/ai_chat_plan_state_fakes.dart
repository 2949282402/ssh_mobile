part of 'ai_chat_plan_state_test.dart';

class _PlanHarness {
  final StorageService storageService;
  final AppSettings appSettings;
  final SshService sshService;
  final SftpService sftpService;
  final PerformanceMonitorService performanceMonitorService;
  final PlaybookService playbookService;
  final RagService ragService;

  _PlanHarness({
    required this.storageService,
    required this.appSettings,
    required this.sshService,
    required this.sftpService,
    required this.performanceMonitorService,
    required this.playbookService,
    required this.ragService,
  });

  static Future<_PlanHarness> create({StorageService? storageService}) async {
    final storage = storageService ?? StorageService();
    await storage.init();
    attachTestAiRepository(storage);
    final settings = AppSettings();
    await settings.init();
    final ssh = SshService(storage);
    final sftp = SftpService(storage);
    final monitor = PerformanceMonitorService(ssh, storage);
    return _PlanHarness(
      storageService: storage,
      appSettings: settings,
      sshService: ssh,
      sftpService: sftp,
      performanceMonitorService: monitor,
      playbookService: PlaybookService(
        storageService: storage,
        sshService: ssh,
      ),
      ragService: RagService(storageService: storage),
    );
  }

  Future<void> saveApiKey() {
    return storageService.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'test-model',
      apiKey: 'test-api-key',
    );
  }

  _PlanRuntimeFactory runtimeFactory({
    _StreamExit exit = _StreamExit.success,
    bool persistTodoDuringStream = false,
  }) {
    return _PlanRuntimeFactory(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
      exit: exit,
      persistTodoDuringStream: persistTodoDuringStream,
    );
  }

  AiChatViewModel viewModel({
    required AiChatRuntimeFactory runtimeFactory,
    ClientHealthAdvisorAdapter healthAdvisor = const _ImmediateHealthAdvisor(),
  }) {
    return createAiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
      runtimeFactory: runtimeFactory,
      clientHealthAdvisor: healthAdvisor,
    );
  }

  void dispose() {
    appSettings.dispose();
    storageService.dispose();
  }
}

class _ImmediateHealthAdvisor implements ClientHealthAdvisorAdapter {
  const _ImmediateHealthAdvisor();

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) async {
    return _okHealthReport;
  }
}

class _DelayedHealthAdvisor implements ClientHealthAdvisorAdapter {
  final Completer<ClientRuntimeHealthReport> _completer = Completer();
  int checks = 0;

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) {
    checks += 1;
    return _completer.future;
  }

  void completeOk() {
    _completer.complete(_okHealthReport);
  }
}

const _okHealthReport = ClientRuntimeHealthReport(
  status: ClientRuntimeHealthStatus.ok,
  issues: [],
  raw: {},
);

class _FailNextChatSaveStorage extends StorageService {
  bool failNextChatSave = false;
  int failedChatSaves = 0;

  @override
  Future<void> saveAiChat(AiChatRecord chat) {
    if (failNextChatSave) {
      failNextChatSave = false;
      failedChatSaves += 1;
      throw StateError('simulated chat save failure');
    }
    return super.saveAiChat(chat);
  }
}

class _GateNextChatSaveStorage extends StorageService {
  Completer<void>? _saveGate;
  Completer<void>? _saveStarted;

  Future<void> get nextChatSaveStarted => _saveStarted!.future;

  void gateNextChatSave() {
    _saveGate = Completer<void>();
    _saveStarted = Completer<void>();
  }

  void releaseChatSave() {
    _saveGate?.complete();
  }

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    final gate = _saveGate;
    if (gate != null) {
      _saveStarted?.complete();
      await gate.future;
      _saveGate = null;
    }
    await super.saveAiChat(chat);
  }
}

class _GateNextSettingsLoadStorage extends StorageService {
  Completer<void>? _settingsGate;
  Completer<void>? _settingsStarted;

  Future<void> get nextSettingsLoadStarted => _settingsStarted!.future;

  void gateNextSettingsLoad() {
    _settingsGate = Completer<void>();
    _settingsStarted = Completer<void>();
  }

  void releaseSettingsLoad() {
    _settingsGate?.complete();
  }

  Future<void> _waitForSettingsGate() async {
    final gate = _settingsGate;
    if (gate != null) {
      _settingsStarted?.complete();
      await gate.future;
      _settingsGate = null;
    }
  }

  @override
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    await _waitForSettingsGate();
    return super.loadAiConnectionSettings();
  }

  @override
  Future<AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot() async {
    await _waitForSettingsGate();
    return super.loadAiRuntimeConnectionSnapshot();
  }
}

class _GateNumberedChatSaveStorage extends StorageService {
  int _chatSaveNumber = 0;
  int? _gatedSaveNumber;
  Completer<void>? _saveGate;
  Completer<void>? _saveStarted;
  int completedChatDeletes = 0;

  Future<void> get gatedChatSaveStarted => _saveStarted!.future;

  void gateChatSaveNumber(int saveNumber) {
    _chatSaveNumber = 0;
    _gatedSaveNumber = saveNumber;
    _saveGate = Completer<void>();
    _saveStarted = Completer<void>();
  }

  void releaseChatSave() {
    _saveGate?.complete();
  }

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    _chatSaveNumber += 1;
    if (_chatSaveNumber == _gatedSaveNumber) {
      _saveStarted?.complete();
      await _saveGate!.future;
      _gatedSaveNumber = null;
    }
    await super.saveAiChat(chat);
  }

  @override
  Future<void> deleteAiChat(String id) async {
    await super.deleteAiChat(id);
    completedChatDeletes += 1;
  }
}

enum _StreamExit { success, cancelled, failed, waitForCancellation }

class _PlanRuntimeFactory extends LegacyAiChatRuntimeFactory {
  final _StreamExit exit;
  final bool persistTodoDuringStream;
  int streamStarts = 0;

  _PlanRuntimeFactory({
    required super.storageService,
    required super.sshService,
    required super.sftpService,
    required super.performanceMonitorService,
    required super.playbookService,
    required super.ragService,
    required super.appSettings,
    required this.exit,
    required this.persistTodoDuringStream,
  });

  @override
  LlmChatService createLlmChatService({
    required AiConnectionSettings settings,
    required String model,
    required String chatId,
    AppLanguage language = AppLanguage.zh,
  }) {
    return _PlanLlmChatService(
      storageService: storageService,
      chatId: chatId,
      exit: exit,
      persistTodoDuringStream: persistTodoDuringStream,
      onStreamStarted: () => streamStarts += 1,
    );
  }
}

class _PlanLlmChatService extends LlmChatService {
  final String chatId;
  final _StreamExit exit;
  final bool persistTodoDuringStream;
  final VoidCallback onStreamStarted;

  _PlanLlmChatService({
    required super.storageService,
    required this.chatId,
    required this.exit,
    required this.persistTodoDuringStream,
    required this.onStreamStarted,
  }) : super(toolService: const _NoopAiToolExecutor());

  @override
  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
    requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    String? runId,
    Set<String>? allowedTools,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool forceContextCompression = false,
    bool planMode = false,
    AiChatMessageRecord? approvedPlanMessage,
  }) async* {
    onStreamStarted();
    if (persistTodoDuringStream) {
      await _persistTodoState();
    }

    switch (exit) {
      case _StreamExit.success:
        onTrace?.call(
          const LlmTraceEvent(
            kind: 'agent_run_summary',
            title: 'Run Summary',
            content: '{"finalOutcome":"success"}',
          ),
        );
        yield 'completed';
        return;
      case _StreamExit.cancelled:
        throw const LlmCancelledException();
      case _StreamExit.failed:
        throw StateError('simulated model failure');
      case _StreamExit.waitForCancellation:
        final cancelled = Completer<void>();
        cancellationToken?.onCancel(cancelled.complete);
        await cancelled.future;
        throw const LlmCancelledException();
    }
  }

  Future<void> _persistTodoState() async {
    final chats = await storageService.loadAiChats();
    final chat = chats.singleWhere((item) => item.id == chatId);
    final messages = [...chat.messages];
    final assistantIndex = messages.lastIndexWhere(
      (message) => message.role == 'assistant',
    );
    if (assistantIndex < 0) {
      throw StateError('assistant placeholder was not persisted');
    }
    messages[assistantIndex] = messages[assistantIndex].copyWith(
      todoSteps: const [
        AiTodoStep(
          id: 'stream-step',
          name: 'Persisted stream task',
          command: 'systemctl restart nginx',
          description: 'Written directly by an LLM tool during streaming',
          status: StepStatus.running,
          stdout: 'saved directly by the LLM tool stream',
        ),
      ],
    );
    await storageService.saveAiChat(
      chat.copyWith(messages: messages, updatedAt: DateTime.now()),
    );
  }
}

class _NoopAiToolExecutor implements AiToolExecutor {
  const _NoopAiToolExecutor();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
