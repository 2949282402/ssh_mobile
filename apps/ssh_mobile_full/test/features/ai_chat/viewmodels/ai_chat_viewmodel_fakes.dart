part of 'ai_chat_viewmodel_test.dart';

class _FailOnceInitialSettingsStorage extends StorageService {
  int settingsLoadAttempts = 0;

  @override
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    settingsLoadAttempts += 1;
    if (settingsLoadAttempts == 1) {
      throw StateError(r'failed to read C:\private\settings.db');
    }
    return super.loadAiConnectionSettings();
  }
}

class _FailPlanModeSaveStorage extends StorageService {
  bool failNextAiChatSave = false;

  @override
  Future<void> saveAiChat(AiChatRecord chat) {
    if (failNextAiChatSave) {
      failNextAiChatSave = false;
      throw StateError('Plan Mode save failed');
    }
    return super.saveAiChat(chat);
  }
}

class FailureLlmChatService extends LlmChatService {
  FailureLlmChatService({required super.storageService})
    : super(toolService: const _FakeAiToolExecutor());

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
  }) {
    throw StateError('Chat service failure');
  }
}

class FakeSuccessLlmChatService extends LlmChatService {
  final String finalOutcome;
  final void Function(Set<String>, Set<String>?)? onStreamStarted;

  FakeSuccessLlmChatService({
    required super.storageService,
    this.finalOutcome = 'success',
    this.onStreamStarted,
  }) : super(toolService: const _FakeAiToolExecutor());

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
    onStreamStarted?.call(
      Set<String>.from(selectedConnectionIds),
      allowedTools == null ? null : Set<String>.from(allowedTools),
    );
    if (onTrace != null) {
      onTrace(
        LlmTraceEvent(
          kind: 'agent_run_summary',
          title: 'Run Summary',
          content:
              '{"finalOutcome":"$finalOutcome","stepsCount":0,"durationMs":0}',
        ),
      );
    }
    if (onStats != null) {
      onStats(
        const LlmRunStats(
          promptTokens: 10,
          completionTokens: 20,
          totalTokens: 30,
          elapsedMs: 100,
          usageFromProvider: true,
          contextTokensBeforeCompression: 10,
          contextWindowTokens: 259000,
          compressed: false,
        ),
      );
    }
    yield 'ok';
  }
}

class _FakeAiToolExecutor implements AiToolExecutor {
  const _FakeAiToolExecutor();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHealthAdvisor implements ClientHealthAdvisorAdapter {
  final ClientRuntimeHealthStatus status;

  const FakeHealthAdvisor(this.status);

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) async {
    if (status == ClientRuntimeHealthStatus.ok) {
      return const ClientRuntimeHealthReport(
        status: ClientRuntimeHealthStatus.ok,
        issues: [],
        raw: {},
      );
    }
    return ClientRuntimeHealthReport(
      status: status,
      issues: [
        ClientRuntimeHealthIssue(
          code: status == ClientRuntimeHealthStatus.blocking
              ? 'network_not_validated'
              : 'battery_optimization_active',
          severity: status,
          title: 'Runtime issue',
          detail: 'Runtime issue detail',
          recommendation: 'Fix runtime issue',
        ),
      ],
      raw: const {},
    );
  }
}

class _GatedHealthAdvisor implements ClientHealthAdvisorAdapter {
  final ClientRuntimeHealthStatus status;
  final Completer<void> _started = Completer<void>();
  final Completer<void> _release = Completer<void>();
  var _checkCount = 0;

  _GatedHealthAdvisor([this.status = ClientRuntimeHealthStatus.ok]);

  Future<void> get started => _started.future;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) async {
    if (_checkCount++ == 0) {
      if (!_started.isCompleted) _started.complete();
      await _release.future;
    }
    return ClientRuntimeHealthReport(
      status: status,
      issues: status == ClientRuntimeHealthStatus.ok
          ? const []
          : [
              ClientRuntimeHealthIssue(
                code: 'battery_optimization_active',
                severity: status,
                title: 'Runtime warning',
                detail: 'Runtime warning detail',
                recommendation: 'Review runtime warning',
              ),
            ],
      raw: const {},
    );
  }
}

class _GateNextChatSaveStorage extends StorageService {
  Completer<void>? _chatSaveGate;
  Completer<void>? _chatSaveStarted;

  Future<void> get nextChatSaveStarted => _chatSaveStarted!.future;

  void gateNextChatSave() {
    _chatSaveGate = Completer<void>();
    _chatSaveStarted = Completer<void>();
  }

  void releaseChatSave() => _chatSaveGate?.complete();

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    final gate = _chatSaveGate;
    if (gate != null) {
      _chatSaveStarted?.complete();
      await gate.future;
      _chatSaveGate = null;
    }
    return super.saveAiChat(chat);
  }
}

class FakeFailureRuntimeFactory extends AiChatRuntimeFactory {
  FakeFailureRuntimeFactory({
    required super.storageService,
    required super.sshService,
    required super.sftpService,
    required super.performanceMonitorService,
    required super.playbookService,
    required super.ragService,
    required super.appSettings,
  });

  @override
  LlmChatService createLlmChatService({
    required AiConnectionSettings settings,
    required String model,
    required String chatId,
    AppLanguage language = AppLanguage.zh,
  }) {
    return FailureLlmChatService(storageService: storageService);
  }
}

class FakeSuccessRuntimeFactory extends AiChatRuntimeFactory {
  final String finalOutcome;
  Set<String>? lastSelectedConnectionIds;
  Set<String>? lastAllowedTools;
  AiConnectionSettings? lastSettings;

  FakeSuccessRuntimeFactory({
    required super.storageService,
    required super.sshService,
    required super.sftpService,
    required super.performanceMonitorService,
    required super.playbookService,
    required super.ragService,
    required super.appSettings,
    this.finalOutcome = 'success',
  });

  @override
  LlmChatService createLlmChatService({
    required AiConnectionSettings settings,
    required String model,
    required String chatId,
    AppLanguage language = AppLanguage.zh,
  }) {
    lastSettings = settings;
    return FakeSuccessLlmChatService(
      storageService: storageService,
      finalOutcome: finalOutcome,
      onStreamStarted: (selectedConnectionIds, allowedTools) {
        lastSelectedConnectionIds = selectedConnectionIds;
        lastAllowedTools = allowedTools;
      },
    );
  }
}

class _RecordingTurnRagService extends RagService {
  String? receivedSearchMode;
  int? receivedLimit;
  bool receivedExpectedKey = false;

  _RecordingTurnRagService({required super.storageService});

  @override
  Future<List<RagChunk>> retrieve(
    String query, {
    int limit = 3,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  }) async {
    receivedSearchMode = searchMode;
    receivedLimit = limit;
    receivedExpectedKey = aliyunApiKey == 'rag-key-a';
    return const [];
  }
}
