import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../services/ai_chat_status_translator.dart';
import '../services/ai_chat_run_metrics_recorder.dart';
import '../services/ai_chat_generation_runner.dart';
import '../services/ai_chat_run_state_reconciler.dart';

export '../services/ai_chat_status_translator.dart' show AgentStatusString;
import '../../../services/ai_tool_service.dart';
import '../../playbook/models/playbook.dart';
import '../../../services/agent_model_profile.dart';
import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../services/ai_chat_runtime_factory.dart';
import '../services/ai_chat_context_builder.dart';
import '../services/ai_chat_message_mapper.dart';
import '../services/plan_command_parser.dart';
import '../services/plan_approval_eligibility.dart';
import '../services/ai_chat_token_estimator.dart';
import '../services/llm_chat_service.dart';
import '../../../services/llm_runtime/llm_runtime_types.dart';
import '../../../services/llm_provider/llm_api_format.dart';
import '../../../services/performance_monitor_service.dart';
import '../../../services/playbook_service.dart';
import '../../../services/rag_service.dart';
import '../../../services/sftp_service.dart';
import '../../../services/ssh_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/client_webview_service.dart';
import '../../../services/client_health_advisor.dart';
import '../../../services/client_system_tool_service.dart';
import '../../../services/connection_target_binding.dart';
import '../../../services/tool_secret_policy.dart';
import '../../connection/models/connection.dart';
import '../../../utils/text_chunker.dart';

part 'ai_chat_viewmodel_approvals.dart';
part 'ai_chat_viewmodel_slash_commands.dart';

@visibleForTesting
String buildApprovedPlanExecutionContext({
  required String userText,
  required AiChatMessageRecord planMessage,
  required AppLanguage language,
}) {
  return const AiChatContextBuilder().buildApprovedPlanExecutionContext(
    userText: userText,
    planMessage: planMessage,
    language: language,
  );
}

// ViewModel与View层通信的状态和返回结果
sealed class SendTextResult {
  const SendTextResult();
}

class SendTextSuccess extends SendTextResult {
  const SendTextSuccess();
}

class SendTextApiKeyMissing extends SendTextResult {
  const SendTextApiKeyMissing();
}

class SendTextEmptyText extends SendTextResult {
  const SendTextEmptyText();
}

class SendTextAlreadySending extends SendTextResult {
  const SendTextAlreadySending();
}

class SendTextNoActiveChat extends SendTextResult {
  const SendTextNoActiveChat();
}

class SendTextTargetChanged extends SendTextResult {
  const SendTextTargetChanged();
}

class SendTextStartCancelled extends SendTextResult {
  const SendTextStartCancelled();
}

class SendTextPlanHasNoSteps extends SendTextResult {
  const SendTextPlanHasNoSteps();
}

class SendTextSlashCommandHandled extends SendTextResult {
  final String feedback;
  const SendTextSlashCommandHandled(this.feedback);
}

class SendTextSlashCommandOpenSkills extends SendTextResult {
  const SendTextSlashCommandOpenSkills();
}

class SendTextSlashCommandOpenToolsSelector extends SendTextResult {
  final List<String> availableTools;
  final Set<String> currentAllowedTools;
  const SendTextSlashCommandOpenToolsSelector({
    required this.availableTools,
    required this.currentAllowedTools,
  });
}

sealed class ApprovePlanExecutionResult {
  final ClientRuntimeHealthReport? healthReport;
  const ApprovePlanExecutionResult({this.healthReport});
}

class ApprovePlanExecutionStarted extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionStarted({super.healthReport});
}

class ApprovePlanExecutionBlocked extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionBlocked(ClientRuntimeHealthReport report)
    : super(healthReport: report);
}

class ApprovePlanExecutionWarning extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionWarning(ClientRuntimeHealthReport report)
    : super(healthReport: report);
}

class ApprovePlanExecutionNoPlan extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionNoPlan();
}

class ApprovePlanExecutionAlreadySending extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionAlreadySending();
}

class ApprovePlanExecutionApiKeyMissing extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionApiKeyMissing({super.healthReport});
}

class ApprovePlanExecutionPlanChanged extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionPlanChanged({super.healthReport});
}

class ApprovePlanExecutionFailed extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionFailed({super.healthReport});
}

class ApprovePlanExecutionCancelled extends ApprovePlanExecutionResult {
  const ApprovePlanExecutionCancelled({super.healthReport});
}

enum SetPlanModeResult { updated, unchanged, busy, targetChanged, failed }

class _ChatTurnInputSnapshot {
  final List<AiChatAttachment> attachments;
  final Set<String> selectedConnectionIds;
  final Map<String, ConnectionTargetBinding> connectionTargets;
  final Set<String>? allowedTools;
  final bool ragEnabled;
  final String ragSearchMode;
  final int ragTopN;
  final AppLanguage language;

  const _ChatTurnInputSnapshot({
    required this.attachments,
    required this.selectedConnectionIds,
    required this.connectionTargets,
    required this.allowedTools,
    required this.ragEnabled,
    required this.ragSearchMode,
    required this.ragTopN,
    required this.language,
  });
}

class _StreamingAssistantTarget {
  final String chatId;
  final DateTime assistantCreatedAt;

  const _StreamingAssistantTarget({
    required this.chatId,
    required this.assistantCreatedAt,
  });
}

class PendingToolApproval {
  final String chatId;
  final AiToolApprovalRequest request;
  final Completer<AiToolApprovalDecision> completer;

  const PendingToolApproval({
    required this.chatId,
    required this.request,
    required this.completer,
  });
}

class AiChatViewModel extends ChangeNotifier {
  static List<String> resolveFetchedModelOptions({
    required Iterable<String> fetchedModels,
    required Iterable<String> fallbackModels,
  }) {
    final normalizedFetched =
        fetchedModels
            .map((model) => model.trim())
            .where((model) => model.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (normalizedFetched.isNotEmpty) {
      return normalizedFetched;
    }

    return fallbackModels
        .map((model) => model.trim())
        .where((model) => model.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  final StorageService _storageService;
  final PlaybookService _playbookService;
  final AppSettings _appSettings;
  final AiChatRuntimeFactory _runtimeFactory;
  final ClientHealthAdvisorAdapter _clientHealthAdvisor;
  late final AiChatContextBuilder _contextBuilder;
  late final AiChatMessageMapper _messageMapper;
  late final AiChatTokenEstimator _tokenEstimator;
  static const ToolSecretPolicy _traceSecretPolicy = ToolSecretPolicy();

  // 聊天会话状态列表
  List<AiChatRecord> _chats = const [];
  List<AiChatRecord> _savedHistoryChats = const [];
  String? _activeChatId;

  // 操作状态
  bool _loading = true;
  bool _settingsLoadStarted = false;
  bool _initialDraftFailed = false;
  bool _historyLoadStarted = false;
  bool _historyLoading = false;
  bool _sending = false;
  bool _sendPreparationInFlight = false;
  bool _sendPreparationCancelled = false;
  bool _sendCommitInProgress = false;
  bool _cancelGenerationOnStart = false;
  bool _planApprovalInFlight = false;
  _PlanApprovalSnapshot? _pendingPlanWarningSnapshot;
  int _chatStateWritesInFlight = 0;
  bool _toolsExpanded = false;

  // 选中的连接和工具权限
  final Set<String> _selectedConnectionIds = {};
  final Map<String, Set<String>> _chatAllowedTools = {};
  final Set<String> _pendingForceCompressionChats = {};
  final List<AiChatAttachment> _pendingAttachments = [];

  // 工具审批
  PendingToolApproval? _pendingApproval;
  LlmCancellationToken? _activeCancellationToken;
  String? _activeGenerationChatId;
  final Set<String> _deletedGenerationChatIds = {};
  final Set<String> _deletedChatIds = {};
  ClientRuntimeHealthReport? _lastRuntimeHealthReport;

  // 上下文限制
  int _contextWindowTokens = AiContextWindowSize.k259;

  // 流式输出ValueNotifier
  final ValueNotifier<String> streamingAssistantText = ValueNotifier<String>(
    '',
  );
  final ValueNotifier<String> streamingAssistantStatus = ValueNotifier<String>(
    '',
  );
  _StreamingAssistantTarget? _streamingAssistantTarget;

  // 通知UI滚动的流
  final StreamController<void> _scrollRequests =
      StreamController<void>.broadcast();

  AiChatViewModel({
    required StorageService storageService,
    required SshService sshService,
    required SftpService sftpService,
    required PerformanceMonitorService performanceMonitorService,
    required PlaybookService playbookService,
    required RagService ragService,
    required AppSettings appSettings,
    AiChatRuntimeFactory? runtimeFactory,
    ClientHealthAdvisorAdapter? clientHealthAdvisor,
    AiChatContextBuilder? contextBuilder,
    AiChatMessageMapper? messageMapper,
    AiChatTokenEstimator? tokenEstimator,
  }) : _storageService = storageService,
       _playbookService = playbookService,
       _appSettings = appSettings,
       _runtimeFactory =
           runtimeFactory ??
           AiChatRuntimeFactory(
             storageService: storageService,
             sshService: sshService,
             sftpService: sftpService,
             performanceMonitorService: performanceMonitorService,
             playbookService: playbookService,
             ragService: ragService,
             appSettings: appSettings,
           ),
       _clientHealthAdvisor =
           clientHealthAdvisor ??
           ClientHealthAdvisor(
             clientSystemToolService: ClientSystemToolService.instance,
           ) {
    final resolvedContextBuilder =
        contextBuilder ?? const AiChatContextBuilder();
    final resolvedMessageMapper =
        messageMapper ??
        AiChatMessageMapper(contextBuilder: resolvedContextBuilder);

    _contextBuilder = resolvedContextBuilder;
    _messageMapper = resolvedMessageMapper;
    _tokenEstimator =
        tokenEstimator ??
        AiChatTokenEstimator(messageMapper: resolvedMessageMapper);
  }

  // Getters
  List<AiChatRecord> get chats => _chats;
  List<AiChatRecord> get savedHistoryChats => _savedHistoryChats;
  String? get activeChatId => _activeChatId;
  bool get loading => _loading;
  bool get initialDraftFailed => _initialDraftFailed;
  bool get historyLoading => _historyLoading;
  bool get sending => _sending;
  bool get planApprovalInFlight => _planApprovalInFlight;
  bool get _chatMutationLocked =>
      _sendPreparationInFlight || _chatStateWritesInFlight > 0;

  bool _tryBeginChatStateWrite({
    bool allowDuringGeneration = false,
    bool allowDuringPlanApproval = false,
  }) {
    if (_chatMutationLocked ||
        (!allowDuringGeneration && _sending) ||
        (!allowDuringPlanApproval && _planApprovalInFlight)) {
      return false;
    }
    _chatStateWritesInFlight += 1;
    return true;
  }

  void _endChatStateWrite() {
    assert(_chatStateWritesInFlight > 0);
    _chatStateWritesInFlight -= 1;
  }

  bool get toolsExpanded => _toolsExpanded;
  Set<String> get selectedConnectionIds =>
      Set.unmodifiable(_selectedConnectionIds);
  List<AiChatAttachment> get pendingAttachments => _pendingAttachments;
  PendingToolApproval? get pendingApproval => _pendingApproval;
  ClientRuntimeHealthReport? get lastRuntimeHealthReport =>
      _lastRuntimeHealthReport;
  int get contextWindowTokens => _contextWindowTokens;
  Stream<void> get scrollRequests => _scrollRequests.stream;

  AiChatRecord? get activeChat {
    for (final chat in _chats) {
      if (chat.id == _activeChatId) return chat;
    }
    return _chats.isEmpty ? null : _chats.first;
  }

  set toolsExpanded(bool value) {
    if (_toolsExpanded != value) {
      _toolsExpanded = value;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_pendingApproval?.completer.isCompleted == false) {
      _pendingApproval!.completer.complete(
        const AiToolApprovalDecision.rejected(),
      );
    }
    _activeCancellationToken?.cancel();
    streamingAssistantText.dispose();
    streamingAssistantStatus.dispose();
    _scrollRequests.close();
    super.dispose();
  }

  void _triggerScroll() {
    _scrollRequests.add(null);
  }

  // 加载初始草稿
  Future<void> loadInitialDraft() async {
    if (_settingsLoadStarted) return;
    _settingsLoadStarted = true;
    _loading = true;
    _initialDraftFailed = false;
    notifyListeners();
    try {
      final settings = await _storageService.loadAiConnectionSettings();
      final draft = _newChatRecord(settings.model);
      _chats = [draft];
      _activeChatId = draft.id;
      _contextWindowTokens = settings.contextWindowTokens;
    } catch (error, stackTrace) {
      _initialDraftFailed = true;
      AppLogService.instance.error(
        'Failed to initialize AI chat',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> retryInitialDraft() async {
    if (_loading || (!_initialDraftFailed && activeChat != null)) return;
    _settingsLoadStarted = false;
    await loadInitialDraft();
  }

  // 加载历史记录
  Future<void> loadHistoryChatsIfNeeded() async {
    if (_historyLoadStarted || _historyLoading) return;
    _historyLoading = true;
    notifyListeners();
    try {
      final chats = (await _storageService.loadAiChats())
          .where((chat) => !_deletedChatIds.contains(chat.id))
          .toList();
      _historyLoadStarted = true;
      final currentChats = List<AiChatRecord>.from(_chats);
      final currentById = {for (final chat in currentChats) chat.id: chat};
      final mergedHistory = <AiChatRecord>[];
      final mergedIds = <String>{};
      for (final storedChat in chats) {
        final current = currentById[storedChat.id];
        mergedHistory.add(
          current != null && current.messages.isNotEmpty ? current : storedChat,
        );
        mergedIds.add(storedChat.id);
      }
      for (final current in currentChats) {
        if (current.messages.isNotEmpty && mergedIds.add(current.id)) {
          mergedHistory.add(current);
        }
      }
      mergedHistory.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _savedHistoryChats = mergedHistory;

      final drafts = currentChats
          .where((chat) => chat.messages.isEmpty)
          .toList();
      final draftIds = drafts.map((chat) => chat.id).toSet();
      _chats = [
        ...drafts,
        ...mergedHistory.where((chat) => !draftIds.contains(chat.id)),
      ];
      _activeChatId ??= _chats.isEmpty ? null : _chats.first.id;
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Failed to load AI chat history',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _historyLoading = false;
      notifyListeners();
    }
  }

  // 创建/切换/删除会话
  Future<String> loadNewChatModel() async =>
      (await _storageService.loadAiConnectionSettings()).model;

  bool createChat(
    String model, {
    Set<String> preserveChatIds = const <String>{},
  }) {
    if (_chatMutationLocked) return false;
    final chat = _newChatRecord(model);
    _chats = [
      chat,
      ..._chats.where(
        (item) => item.messages.isNotEmpty || preserveChatIds.contains(item.id),
      ),
    ];
    _activeChatId = chat.id;
    notifyListeners();
    _triggerScroll();
    return true;
  }

  void selectChat(String id) {
    if (_chatMutationLocked) return;
    if (_activeChatId == id) return;
    _activeChatId = id;
    notifyListeners();
    _triggerScroll();
  }

  Future<void> deleteChat(String id) async {
    if (!_tryBeginChatStateWrite(
      allowDuringGeneration: true,
      allowDuringPlanApproval: true,
    )) {
      return;
    }
    try {
      if (_chats.isEmpty && _savedHistoryChats.isEmpty) return;
      if (_activeGenerationChatId == id) {
        _deletedGenerationChatIds.add(id);
        _activeCancellationToken?.cancel();
        final pending = _pendingApproval;
        if (pending?.chatId == id && !pending!.completer.isCompleted) {
          pending.completer.complete(
            const AiToolApprovalDecision.rejected(abort: true),
          );
          _pendingApproval = null;
        }
      }
      final deleted = _chatById(id);
      if (deleted != null) _deletedChatIds.add(id);
      _chatAllowedTools.remove(id);
      _pendingForceCompressionChats.remove(id);
      final nextChats = _chats.where((chat) => chat.id != id).toList();
      if (nextChats.isEmpty) {
        final settings = await _storageService.loadAiConnectionSettings();
        nextChats.add(_newChatRecord(settings.model));
      }
      _chats = nextChats;
      _savedHistoryChats = _savedHistoryChats
          .where((chat) => chat.id != id)
          .toList();
      if (_activeChatId == id || _activeChatId == null) {
        _activeChatId = nextChats.first.id;
      }
      notifyListeners();
      if (deleted?.messages.isNotEmpty == true) {
        await _storageService.deleteAiChat(id);
      }
      ClientWebViewService.instance.clearSession(id);
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }
  }

  Future<bool> updateActiveChat(AiChatRecord chat) async {
    if (chat.id != _activeChatId || !_tryBeginChatStateWrite()) return false;
    try {
      await _storageService.saveAiChat(chat);
      _replaceChat(chat, activate: false);
      notifyListeners();
      return true;
    } finally {
      _endChatStateWrite();
    }
  }

  Future<SetPlanModeResult> setPlanModeForActiveChat({
    required String chatId,
    required bool enabled,
  }) async {
    if (_sending || _planApprovalInFlight || _chatMutationLocked) {
      return SetPlanModeResult.busy;
    }
    final chat = activeChat;
    if (chat == null || chat.id != chatId || _activeChatId != chatId) {
      return SetPlanModeResult.targetChanged;
    }
    if (chat.planMode == enabled && (!enabled || chat.approvedPlan == null)) {
      return SetPlanModeResult.unchanged;
    }

    final updated = chat.copyWith(
      planMode: enabled,
      updatedAt: DateTime.now(),
      clearApprovedPlan: enabled,
    );
    try {
      final saved = await updateActiveChat(updated);
      return saved ? SetPlanModeResult.updated : SetPlanModeResult.busy;
    } catch (_, stackTrace) {
      AppLogService.instance.error(
        'Plan Mode update failed',
        details: 'chatId=$chatId enabled=$enabled',
        stackTrace: stackTrace,
      );
      return SetPlanModeResult.failed;
    }
  }

  // 附件操作
  void addAttachment(AiChatAttachment attachment) {
    _pendingAttachments.add(attachment);
    notifyListeners();
  }

  void removeAttachmentAt(int index) {
    if (index >= 0 && index < _pendingAttachments.length) {
      _pendingAttachments.removeAt(index);
      notifyListeners();
    }
  }

  void clearAttachments() {
    _pendingAttachments.clear();
    notifyListeners();
  }

  // 选择服务器连接
  void updateSelectedConnections(Set<String> connectionIds) {
    _selectedConnectionIds.clear();
    _selectedConnectionIds.addAll(connectionIds);
    notifyListeners();
  }

  ConnectionConfig? getConnection(String id) {
    return _storageService.getConnection(id);
  }

  List<ConnectionConfig> get connections => _storageService.connections;

  String? checkPendingDiagnosticPrompt() {
    final prompt = _playbookService.pendingDiagnosticPrompt;
    if (prompt != null) {
      _playbookService.pendingDiagnosticPrompt = null;
    }
    return prompt;
  }

  Future<Map<String, dynamic>> loadLlmSettingsData() async {
    final settings = await _storageService.loadAiConnectionSettings();
    final cachedModels = await _storageService.loadCachedAiModels(
      baseUrl: settings.baseUrl,
    );
    final baseUrlHistory = await _storageService.loadAiBaseUrlHistory();
    final apiKeyHistory = await _storageService.loadAiApiKeyHistory();
    return {
      'settings': settings,
      'cachedModels': cachedModels,
      'baseUrlHistory': baseUrlHistory,
      'apiKeyHistory': apiKeyHistory,
    };
  }

  void logLlmSettingsOpened(AiConnectionSettings settings) {
    AppLogService.instance.info(
      'LLM settings page opened',
      details:
          'hasBaseUrl=${settings.baseUrl.trim().isNotEmpty} modelConfigured=${settings.model.trim().isNotEmpty} hasApiKey=${settings.hasApiKey}',
    );
  }

  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    return await _storageService.loadAiConnectionSettings();
  }

  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    String? helperModel,
    String? auditModel,
    String? modelFallbackPolicy,
    int? contextWindowTokens,
    int? timeoutSeconds,
    bool? deepSeekThinkingEnabled,
    String? deepSeekReasoningEffort,
    String? openAiReasoningEffort,
    bool? webSearchEnabled,
    int? webSearchMaxResults,
    String? webSearchEngine,
    bool? multiAgentEnabled,
    int? multiAgentMaxAgents,
    bool? postToolReviewEnabled,
    int? toolCallBudget,
    String? agentLoopMode,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    String? apiKey,
    String? selectedApiKeyId,
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    LlmApiFormat? apiFormat,
  }) async {
    try {
      await _storageService.saveAiConnectionSettings(
        baseUrl: baseUrl,
        model: model,
        helperModel: helperModel,
        auditModel: auditModel,
        modelFallbackPolicy: modelFallbackPolicy,
        contextWindowTokens: contextWindowTokens,
        timeoutSeconds: timeoutSeconds,
        deepSeekThinkingEnabled: deepSeekThinkingEnabled,
        deepSeekReasoningEffort: deepSeekReasoningEffort,
        openAiReasoningEffort: openAiReasoningEffort,
        webSearchEnabled: webSearchEnabled,
        webSearchMaxResults: webSearchMaxResults,
        webSearchEngine: webSearchEngine,
        multiAgentEnabled: multiAgentEnabled,
        multiAgentMaxAgents: multiAgentMaxAgents,
        postToolReviewEnabled: postToolReviewEnabled,
        toolCallBudget: toolCallBudget,
        agentLoopMode: agentLoopMode,
        maxImageSizeBytes: maxImageSizeBytes,
        maxFileSizeBytes: maxFileSizeBytes,
        apiKey: apiKey,
        selectedApiKeyId: selectedApiKeyId,
        clearApiKey: clearApiKey,
        quarkSearchEndpoint: quarkSearchEndpoint,
        quarkApiKey: quarkApiKey,
        clearQuarkApiKey: clearQuarkApiKey,
        useCustomPrompts: useCustomPrompts,
        customSystemPrompt: customSystemPrompt,
        customPlannerPrompt: customPlannerPrompt,
        customOperatorPrompt: customOperatorPrompt,
        customExplorePrompt: customExplorePrompt,
        customReviewerPrompt: customReviewerPrompt,
        customSummarizerPrompt: customSummarizerPrompt,
        customCoordinatorPrompt: customCoordinatorPrompt,
        apiFormat: apiFormat,
      );
      notifyListeners();
    } catch (_, stackTrace) {
      AppLogService.instance.error(
        'LLM settings save failed',
        stackTrace: stackTrace,
        details:
            'hasBaseUrl=${baseUrl.trim().isNotEmpty} modelConfigured=${model.trim().isNotEmpty} hasApiKeyInput=${apiKey?.trim().isNotEmpty == true} selectedApiKey=${selectedApiKeyId?.trim().isNotEmpty == true}',
      );
      rethrow;
    }
  }

  Future<List<String>> loadCachedAiModels({String? baseUrl}) async {
    return await _storageService.loadCachedAiModels(baseUrl: baseUrl);
  }

  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) async {
    await _storageService.removeAiBaseUrlHistoryEntry(baseUrl);
  }

  Future<void> removeAiApiKeyHistoryEntry(String id) async {
    await _storageService.removeAiApiKeyHistoryEntry(id);
  }

  Future<List<AiApiKeyHistoryEntry>> loadAiApiKeyHistory() async {
    return await _storageService.loadAiApiKeyHistory();
  }

  Future<String?> getAiApiKeyById(String id) async {
    return await _storageService.getAiApiKeyById(id);
  }

  Future<String?> getAliyunApiKey() async {
    return await _storageService.getAliyunApiKey();
  }

  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) async {
    await _storageService.saveCachedAiModels(baseUrl: baseUrl, models: models);
  }

  Future<List<String>> fetchModelsFromProvider({
    required String baseUrl,
    required String? typedApiKey,
    required String? selectedApiKeyId,
    required List<String> fallbackModels,
  }) async {
    final settings = await _storageService.loadAiConnectionSettings();
    final resolvedApiKey = typedApiKey?.trim().isNotEmpty == true
        ? typedApiKey!.trim()
        : (selectedApiKeyId == null
              ? null
              : await _storageService.getAiApiKeyById(selectedApiKeyId));

    final service = _runtimeFactory.createLlmChatService(
      settings: settings,
      model: settings.model,
      chatId: _activeChatId ?? '',
      language: _appSettings.language,
    );

    final fetched = await service.fetchModels(
      baseUrl: baseUrl.trim(),
      apiKey: resolvedApiKey,
    );

    final resolvedModels = resolveFetchedModelOptions(
      fetchedModels: fetched,
      fallbackModels: fallbackModels,
    );

    await _storageService.saveCachedAiModels(
      baseUrl: baseUrl.trim(),
      models: resolvedModels,
    );

    return resolvedModels;
  }

  void updateAllowedTools(String chatId, Set<String> allowedTools) {
    _chatAllowedTools[chatId] = Set<String>.from(allowedTools);
    notifyListeners();
  }

  void _reserveSendPreparation() {
    _sendPreparationCancelled = false;
    _sendCommitInProgress = false;
    _cancelGenerationOnStart = false;
    _sendPreparationInFlight = true;
    _sending = true;
    notifyListeners();
  }

  void _releaseSendPreparation() {
    final changed = _sendPreparationInFlight || _sending;
    _sendPreparationInFlight = false;
    _sendCommitInProgress = false;
    _cancelGenerationOnStart = false;
    _sending = false;
    if (changed) notifyListeners();
  }

  Future<AiChatRecord?> _enablePlanModeForChat(AiChatRecord chat) async {
    if (chat.id != _activeChatId || !_tryBeginChatStateWrite()) return null;
    try {
      final updated = chat.copyWith(
        planMode: true,
        updatedAt: DateTime.now(),
        clearApprovedPlan: true,
      );
      await _storageService.saveAiChat(updated);
      _replaceChat(updated, activate: false);
      notifyListeners();
      return updated;
    } finally {
      _endChatStateWrite();
    }
  }

  Future<({AiChatRecord chat, AiRuntimeConnectionSnapshot runtimeConnection})?>
  _preparePlanModeSend(AiChatRecord chat) async {
    if (chat.id != _activeChatId || !_tryBeginChatStateWrite()) return null;
    try {
      final runtimeConnection = await _storageService
          .loadAiRuntimeConnectionSnapshot();
      final updated = chat.copyWith(
        planMode: true,
        updatedAt: DateTime.now(),
        clearApprovedPlan: true,
      );
      await _storageService.saveAiChat(updated);
      _replaceChat(updated, activate: false);
      notifyListeners();
      return (chat: updated, runtimeConnection: runtimeConnection);
    } finally {
      _endChatStateWrite();
    }
  }

  // 发送逻辑
  Future<SendTextResult> sendText({
    required String text,
    AiApprovedPlanRef? approvedPlanRef,
  }) async {
    var activeChat = this.activeChat;
    if (text.isEmpty) return const SendTextEmptyText();
    if (_sending ||
        _sendPreparationInFlight ||
        _planApprovalInFlight ||
        _chatStateWritesInFlight > 0) {
      return const SendTextAlreadySending();
    }
    if (activeChat == null) return const SendTextNoActiveChat();
    final turnInputSnapshot = _captureTurnInputSnapshot(chatId: activeChat.id);

    var targetText = text.trim();
    AiRuntimeConnectionSnapshot? capturedRuntimeConnection;
    if (targetText.startsWith('/')) {
      final planCommand = parsePlanCommand(targetText);
      if (planCommand?.hasArguments == true) {
        final prepared = await _preparePlanModeSend(activeChat);
        if (prepared == null) return const SendTextAlreadySending();

        activeChat = prepared.chat;
        capturedRuntimeConnection = prepared.runtimeConnection;
        targetText = planCommand!.arguments;
      } else {
        final handledResult = await _executeSlashCommand(
          chatId: activeChat.id,
          input: targetText,
        );
        if (handledResult != null) {
          return handledResult;
        }
      }
    }

    _reserveSendPreparation();
    try {
      final runtimeConnection =
          capturedRuntimeConnection ??
          await _storageService.loadAiRuntimeConnectionSnapshot();
      final settings = runtimeConnection.settings;
      if (_sendPreparationCancelled || !_sendPreparationInFlight) {
        _releaseSendPreparation();
        return const SendTextStartCancelled();
      }
      final currentModel = settings.model.trim();
      if (!runtimeConnection.hasApiKey) {
        AppLogService.instance.warning(
          'LLM chat blocked: API key missing or invalid',
          details: 'model=$currentModel',
        );
        _releaseSendPreparation();
        return const SendTextApiKeyMissing();
      }

      return await _startTextGeneration(
        chat: activeChat,
        targetText: targetText,
        runtimeConnection: runtimeConnection,
        approvedPlanRef: approvedPlanRef,
        turnInputSnapshot: turnInputSnapshot,
        preparationReserved: true,
      );
    } catch (_) {
      _releaseSendPreparation();
      rethrow;
    }
  }

  Future<SendTextResult> _startTextGeneration({
    required AiChatRecord chat,
    required String targetText,
    required AiRuntimeConnectionSnapshot runtimeConnection,
    AiApprovedPlanRef? approvedPlanRef,
    _ChatTurnInputSnapshot? turnInputSnapshot,
    bool Function()? canCommit,
    bool preparationReserved = false,
  }) async {
    if (preparationReserved) {
      if (_sendPreparationCancelled) {
        return const SendTextStartCancelled();
      }
      if (!_sendPreparationInFlight || !_sending) {
        return const SendTextAlreadySending();
      }
    } else if (_sending || _sendPreparationInFlight) {
      return const SendTextAlreadySending();
    }
    if (canCommit != null && !canCommit()) {
      return const SendTextTargetChanged();
    }

    if (!preparationReserved) {
      _reserveSendPreparation();
    }

    try {
      final settings = runtimeConnection.settings;
      final currentModel = settings.model.trim();
      final chatId = chat.id;
      final now = DateTime.now();
      final turnInput =
          turnInputSnapshot ?? _captureTurnInputSnapshot(chatId: chatId);

      // RAG 检索
      final attachments = List<AiChatAttachment>.from(turnInput.attachments);
      final orchestrator = _runtimeFactory.createOrchestrator();

      final preparedTurn = await orchestrator.prepareTurn(
        chat: chat,
        text: targetText,
        createdAt: now,
        language: turnInput.language,
        attachments: attachments,
        selectedConnectionIds: turnInput.selectedConnectionIds,
        connectionTargets: turnInput.connectionTargets,
        approvedPlanRef: approvedPlanRef,
        ragEnabled: turnInput.ragEnabled,
        ragSearchMode: turnInput.ragSearchMode,
        ragLimit: turnInput.ragTopN,
        ragAliyunApiKey: runtimeConnection.aliyunApiKey,
      );
      if (_sendPreparationCancelled || !_sendPreparationInFlight) {
        _releaseSendPreparation();
        return const SendTextStartCancelled();
      }
      if (canCommit != null && !canCommit()) {
        _releaseSendPreparation();
        return const SendTextTargetChanged();
      }
      final userMessage = preparedTurn.userMessage;
      final ragChunks = const <RagChunk>[];

      // RAG Traces
      final assistantTraces = List<AiMessageTrace>.from(
        preparedTurn.assistantMessage.traces,
      );
      if (ragChunks.isNotEmpty) {
        final traceContent = StringBuffer();
        final isEn = _appSettings.isEnglish;
        for (final chunk in ragChunks) {
          traceContent.writeln(
            isEn
                ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
                : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})',
          );
          traceContent.writeln('---');
          traceContent.writeln(chunk.text);
          traceContent.writeln('========================================\n');
        }
        assistantTraces.add(
          AiMessageTrace(
            id: 'rag-${now.microsecondsSinceEpoch}',
            kind: 'rag_context',
            title: isEn ? 'Knowledge Base Retrieval (RAG)' : '知识库检索 (RAG)',
            content: traceContent.toString(),
            createdAt: now,
          ),
        );
      }

      final assistantMessage = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        traces: assistantTraces,
        createdAt: now,
      );
      final nextMessages = [...chat.messages, userMessage, assistantMessage];
      final nextChat = chat.copyWith(
        title: chat.messages.isEmpty ? _titleFrom(targetText) : null,
        model: currentModel.isNotEmpty ? currentModel : chat.model,
        messages: nextMessages,
        updatedAt: now,
        approvedPlan: approvedPlanRef,
      );

      _sendCommitInProgress = true;
      await _storageService.saveAiChat(nextChat);

      _replaceChat(nextChat, activate: _activeChatId == chatId);
      _removePendingAttachmentSnapshot(attachments);
      _toolsExpanded = false;
      notifyListeners();
      _triggerScroll();

      unawaited(
        _generateAssistantResponse(
          chatId: chatId,
          initialChat: nextChat,
          assistantMessage: assistantMessage,
          model: currentModel.isNotEmpty ? currentModel : nextChat.model,
          requestMessages: nextMessages,
          userRequest: targetText,
          memorySources: preparedTurn.memorySources,
          ragHits: preparedTurn.ragHits,
          selectedConnectionIds: turnInput.selectedConnectionIds,
          connectionTargets: turnInput.connectionTargets,
          allowedTools: turnInput.allowedTools,
          runtimeConnection: runtimeConnection,
          language: turnInput.language,
        ),
      );
      _sendCommitInProgress = false;
      _sendPreparationInFlight = false;

      return const SendTextSuccess();
    } catch (_) {
      _releaseSendPreparation();
      rethrow;
    }
  }

  void _removePendingAttachmentSnapshot(
    Iterable<AiChatAttachment> consumedAttachments,
  ) {
    for (final consumed in consumedAttachments) {
      final index = _pendingAttachments.indexWhere(
        (pending) => identical(pending, consumed),
      );
      if (index >= 0) {
        _pendingAttachments.removeAt(index);
      }
    }
  }

  _ChatTurnInputSnapshot _captureTurnInputSnapshot({
    required String chatId,
    bool includeAttachments = true,
  }) {
    final allowedTools = _chatAllowedTools[chatId];
    final connectionTargets = <String, ConnectionTargetBinding>{};
    for (final id in _selectedConnectionIds) {
      final connection = _storageService.getConnection(id);
      if (connection != null) {
        connectionTargets[id] = ConnectionTargetBinding.fromConfig(connection);
      }
    }
    return _ChatTurnInputSnapshot(
      attachments: includeAttachments
          ? List<AiChatAttachment>.unmodifiable(_pendingAttachments)
          : const <AiChatAttachment>[],
      selectedConnectionIds: Set<String>.unmodifiable(_selectedConnectionIds),
      connectionTargets: Map<String, ConnectionTargetBinding>.unmodifiable(
        connectionTargets,
      ),
      allowedTools: allowedTools == null
          ? null
          : Set<String>.unmodifiable(allowedTools),
      ragEnabled: _appSettings.ragEnabled,
      ragSearchMode: switch (_appSettings.ragSearchMode) {
        'vector' => 'vector',
        'hybrid' => 'hybrid',
        _ => 'bm25',
      },
      ragTopN: _appSettings.ragTopN.clamp(1, 10),
      language: _appSettings.language,
    );
  }

  Future<void> retryTodoStep(String taskId) async {
    if (!_tryBeginChatStateWrite()) return;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;

      final messages = [...activeChat.messages];
      bool found = false;

      for (var mIdx = 0; mIdx < messages.length; mIdx++) {
        final msg = messages[mIdx];
        if (msg.todoSteps.isEmpty) continue;

        final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
        if (sIdx != -1) {
          final steps = [...msg.todoSteps];
          steps[sIdx] = steps[sIdx].copyWith(
            status: StepStatus.pending,
            stdout: '',
            stderr: '',
            exitCode: null,
          );
          messages[mIdx] = msg.copyWith(todoSteps: steps);
          found = true;
          break;
        }
      }

      if (found) {
        final updated = activeChat.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        );
        await _storageService.saveAiChat(updated);
        _replaceChat(updated, sort: false, activate: false);
        notifyListeners();
      }
    } finally {
      _endChatStateWrite();
    }
  }

  Future<void> skipTodoStep(String taskId, String reason) async {
    if (!_tryBeginChatStateWrite()) return;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;

      final messages = [...activeChat.messages];
      bool found = false;

      for (var mIdx = 0; mIdx < messages.length; mIdx++) {
        final msg = messages[mIdx];
        if (msg.todoSteps.isEmpty) continue;

        final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
        if (sIdx != -1) {
          final steps = [...msg.todoSteps];
          steps[sIdx] = steps[sIdx].copyWith(
            status: StepStatus.skipped,
            stdout: 'Skipped: $reason',
            exitCode: null,
          );
          messages[mIdx] = msg.copyWith(todoSteps: steps);
          found = true;
          break;
        }
      }

      if (found) {
        final updated = activeChat.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        );
        await _storageService.saveAiChat(updated);
        _replaceChat(updated, sort: false, activate: false);
        notifyListeners();
      }
    } finally {
      _endChatStateWrite();
    }
  }

  void stopGeneration() {
    if (!_sending) return;
    if (_sendPreparationInFlight) {
      if (_sendCommitInProgress) {
        _cancelGenerationOnStart = true;
      } else {
        _sendPreparationCancelled = true;
        _sendPreparationInFlight = false;
        _sending = false;
      }
      notifyListeners();
      return;
    }
    _activeCancellationToken?.cancel();
    final pending = _pendingApproval;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(
        const AiToolApprovalDecision.rejected(abort: true),
      );
    }
    _pendingApproval = null;
    notifyListeners();
  }

  Future<void> regenerateAssistant(int messageIndex) async {
    if (!_tryBeginChatStateWrite()) return;
    late AiChatRecord nextChat;
    late AiChatMessageRecord assistantMessage;
    late List<AiChatMessageRecord> nextMessages;
    late String nextModel;
    late String userRequest;
    late _ChatTurnInputSnapshot turnInputSnapshot;
    late AiRuntimeConnectionSnapshot runtimeConnection;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;
      if (messageIndex < 0 || messageIndex >= activeChat.messages.length) {
        return;
      }
      final target = activeChat.messages[messageIndex];
      if (target.role != 'assistant') return;
      turnInputSnapshot = _captureTurnInputSnapshot(
        chatId: activeChat.id,
        includeAttachments: false,
      );

      runtimeConnection = await _storageService
          .loadAiRuntimeConnectionSnapshot();
      final settings = runtimeConnection.settings;
      if (!runtimeConnection.hasApiKey) return;

      final prefix = activeChat.messages.take(messageIndex).toList();
      if (prefix.where((message) => message.role == 'user').isEmpty) return;
      final now = DateTime.now();
      assistantMessage = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
      );
      nextMessages = [...prefix, assistantMessage];
      nextModel = settings.model.trim().isNotEmpty
          ? settings.model
          : activeChat.model;
      nextChat = activeChat.copyWith(
        model: nextModel,
        messages: nextMessages,
        updatedAt: now,
      );
      userRequest = prefix.lastWhere((message) => message.role == 'user').text;

      await _storageService.saveAiChat(nextChat);
      _replaceChat(nextChat, activate: false);
      _sending = true;
      notifyListeners();
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }

    await _generateAssistantResponse(
      chatId: nextChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: userRequest,
      memorySources: const [],
      ragHits: 0,
      selectedConnectionIds: turnInputSnapshot.selectedConnectionIds,
      connectionTargets: turnInputSnapshot.connectionTargets,
      allowedTools: turnInputSnapshot.allowedTools,
      runtimeConnection: runtimeConnection,
      language: turnInputSnapshot.language,
    );
  }

  Future<void> editUserMessage(
    int messageIndex,
    String trimmedEditedText,
  ) async {
    if (trimmedEditedText.isEmpty || !_tryBeginChatStateWrite()) return;
    late AiChatRecord nextChat;
    late AiChatMessageRecord assistantMessage;
    late List<AiChatMessageRecord> nextMessages;
    late String nextModel;
    late _ChatTurnInputSnapshot turnInputSnapshot;
    late AiRuntimeConnectionSnapshot runtimeConnection;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;
      if (messageIndex < 0 || messageIndex >= activeChat.messages.length) {
        return;
      }
      final target = activeChat.messages[messageIndex];
      if (target.role != 'user') return;
      turnInputSnapshot = _captureTurnInputSnapshot(
        chatId: activeChat.id,
        includeAttachments: false,
      );

      final targetIndex = activeChat.messages.indexWhere(
        (message) =>
            message.role == 'user' && message.createdAt == target.createdAt,
      );
      if (targetIndex < 0 || targetIndex >= activeChat.messages.length) {
        return;
      }

      runtimeConnection = await _storageService
          .loadAiRuntimeConnectionSnapshot();
      final settings = runtimeConnection.settings;
      if (!runtimeConnection.hasApiKey) return;

      final currentTarget = activeChat.messages[targetIndex];
      if (currentTarget.role != 'user') return;

      final now = DateTime.now();
      final editedUser = currentTarget.copyWith(
        text: trimmedEditedText,
        createdAt: now,
      );
      assistantMessage = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
      );
      nextMessages = [
        ...activeChat.messages.take(targetIndex),
        editedUser,
        assistantMessage,
      ];
      nextModel = settings.model.trim().isNotEmpty
          ? settings.model
          : activeChat.model;
      nextChat = activeChat.copyWith(
        title: targetIndex == 0 ? _titleFrom(trimmedEditedText) : null,
        model: nextModel,
        messages: nextMessages,
        updatedAt: now,
      );

      await _storageService.saveAiChat(nextChat);
      _replaceChat(nextChat, activate: false);
      _sending = true;
      notifyListeners();
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }

    await _generateAssistantResponse(
      chatId: nextChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: trimmedEditedText,
      memorySources: const [],
      ragHits: 0,
      selectedConnectionIds: turnInputSnapshot.selectedConnectionIds,
      connectionTargets: turnInputSnapshot.connectionTargets,
      allowedTools: turnInputSnapshot.allowedTools,
      runtimeConnection: runtimeConnection,
      language: turnInputSnapshot.language,
    );
  }

  Future<void> branchFromAssistant(int messageIndex) async {
    if (!_tryBeginChatStateWrite()) return;
    try {
      final activeChat = this.activeChat;
      if (activeChat == null) return;
      if (messageIndex < 0 || messageIndex >= activeChat.messages.length) {
        return;
      }
      final target = activeChat.messages[messageIndex];
      if (target.role != 'assistant') return;

      final now = DateTime.now();
      final isEn = _appSettings.language == AppLanguage.en;
      final branch = AiChatRecord(
        id: 'ai-${now.microsecondsSinceEpoch}',
        title: '${activeChat.title} ${isEn ? 'Branch' : '分支'}',
        model: activeChat.model,
        messages: activeChat.messages.take(messageIndex + 1).toList(),
        createdAt: now,
        updatedAt: now,
      );

      await _storageService.saveAiChat(branch);
      _chats = [branch, ..._chats];
      if (branch.messages.isNotEmpty) {
        _savedHistoryChats = [branch, ..._savedHistoryChats];
      }
      _activeChatId = branch.id;
      notifyListeners();
      _triggerScroll();
    } finally {
      _endChatStateWrite();
    }
  }

  // 上下文 Token 压缩与估计逻辑 (吸收自原 chat_token_compression.dart)
  // 上下文 Token 压缩与估计逻辑
  Future<String?> contextTextForUser(
    String text, {
    List<RagChunk> ragChunks = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) async {
    final selected = <AiChatSelectedConnectionContext>[];
    for (final id in _selectedConnectionIds) {
      final conn = _storageService.getConnection(id);
      if (conn != null) {
        selected.add(
          AiChatSelectedConnectionContext(
            id: conn.id,
            name: conn.name,
            username: conn.username,
            host: conn.host,
            port: conn.port,
          ),
        );
      }
    }
    return _contextBuilder.buildUserContextText(
      text: text,
      language: _appSettings.language,
      isEnglish: _appSettings.isEnglish,
      selectedConnections: selected,
      ragChunks: ragChunks,
      approvedPlanMessage: approvedPlanMessage,
    );
  }

  String _contextTextForAssistant(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) {
    return _contextBuilder.buildAssistantContextText(text, traces: traces);
  }

  int contextTokensFor(AiChatRecord chat) {
    return _tokenEstimator.contextTokensFor(chat, sending: _sending);
  }

  ValueListenable<String>? streamingTextFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return streamingAssistantText;
  }

  ValueListenable<String>? streamingStatusFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return streamingAssistantStatus;
  }

  // 私有辅助方法
  AiChatRecord? _chatById(String id) {
    for (final chat in _chats) {
      if (chat.id == id) return chat;
    }
    for (final chat in _savedHistoryChats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  void _replaceChat(
    AiChatRecord chat, {
    bool sort = true,
    bool activate = true,
  }) {
    _chats = sort
        ? upsertAiChatRecordsByUpdatedAt(_chats, chat)
        : _replaceChatWithoutReordering(_chats, chat);
    if (chat.messages.isNotEmpty) {
      _savedHistoryChats = sort && _historyLoadStarted
          ? upsertAiChatRecordsByUpdatedAt(_savedHistoryChats, chat)
          : _replaceChatWithoutReordering(
              _savedHistoryChats,
              chat,
              insertIfMissing: false,
            );
    }
    if (activate) {
      _activeChatId = chat.id;
    }
  }

  List<AiChatRecord> _replaceChatWithoutReordering(
    List<AiChatRecord> chats,
    AiChatRecord chat, {
    bool insertIfMissing = true,
  }) {
    final index = chats.indexWhere((item) => item.id == chat.id);
    if (index >= 0) {
      return [...chats]..[index] = chat;
    }
    return insertIfMissing ? [chat, ...chats] : chats;
  }

  AiChatRecord _newChatRecord(String model) {
    final now = DateTime.now();
    final isEn = _appSettings.language == AppLanguage.en;
    return AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: isEn ? 'New chat' : '新对话',
      model: model,
      messages: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  String _titleFrom(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) {
      return _appSettings.language == AppLanguage.en ? 'New chat' : '新对话';
    }
    return cleaned.length > 22 ? '${cleaned.substring(0, 22)}...' : cleaned;
  }

  List<Map<String, dynamic>> _messagesForRequest(
    List<AiChatMessageRecord> messages, {
    AiChatMessageRecord? placeholder,
  }) {
    return _messageMapper.messagesForRequest(
      messages,
      placeholder: placeholder,
    );
  }

  static List<Map<String, dynamic>> buildMultipartContent(
    String textContent,
    List<AiChatAttachment> attachments,
  ) {
    return AiChatMessageMapper.buildMultipartContent(textContent, attachments);
  }

  Future<AiChatRecord> _reconciledChatForRun({
    required String chatId,
    required AiChatRecord fallback,
  }) async {
    final memoryChat = _chatById(chatId) ?? fallback;
    try {
      final persistedChats = await _storageService.loadAiChats();
      final persistedIndex = persistedChats.indexWhere(
        (chat) => chat.id == chatId,
      );
      if (persistedIndex < 0) return memoryChat;
      return const AiChatRunStateReconciler().reconcile(
        memoryChat: memoryChat,
        persistedChat: persistedChats[persistedIndex],
      );
    } catch (_) {
      AppLogService.instance.warning(
        'Failed to reconcile persisted AI chat run state',
        details: 'chatId=$chatId',
      );
      return memoryChat;
    }
  }

  // LLM流输出核心实现
  Future<void> _generateAssistantResponse({
    required String chatId,
    required AiChatRecord initialChat,
    required AiChatMessageRecord assistantMessage,
    required String model,
    required List<AiChatMessageRecord> requestMessages,
    required String userRequest,
    required List<String> memorySources,
    required int ragHits,
    required Set<String> selectedConnectionIds,
    required Map<String, ConnectionTargetBinding> connectionTargets,
    required Set<String>? allowedTools,
    required AiRuntimeConnectionSnapshot runtimeConnection,
    required AppLanguage language,
  }) async {
    final cancellationToken = LlmCancellationToken();
    _activeCancellationToken = cancellationToken;
    _activeGenerationChatId = chatId;
    if (_cancelGenerationOnStart) {
      _cancelGenerationOnStart = false;
      cancellationToken.cancel();
    }

    try {
      final settings = runtimeConnection.settings;
      if (_deletedGenerationChatIds.contains(chatId)) return;
      final modelProfile = AgentModelProfile(
        mainModel: model,
        helperModel: settings.helperModel,
        auditModel: settings.auditModel,
        fallbackPolicy: settings.modelFallbackPolicy,
      );

      final translator = AiChatStatusTranslator(language);
      final metricsRecorder = AiChatRunMetricsRecorder(_storageService);
      final runner = AiChatGenerationRunner(runtimeFactory: _runtimeFactory);
      final answer = StringBuffer();
      final forceContextCompression = _consumeContextCompression(chatId);
      _beginStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
        status: translator.translateStatus(AgentStatusString.preparing),
      );

      var lastStreamUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

      final runResult = await runner.run(
        chatId: chatId,
        initialChat: initialChat,
        model: model,
        userRequest: userRequest,
        memorySources: memorySources,
        allowedTools: allowedTools,
        forceContextCompression: forceContextCompression,
        cancellationToken: cancellationToken,
        selectedConnectionIds: selectedConnectionIds,
        connectionTargets: connectionTargets,
        language: language,
        runtimeConnectionSnapshot: runtimeConnection,
        requestMessagesJson: _messagesForRequest(
          requestMessages,
          placeholder: assistantMessage,
        ),
        onTextChunk: (chunk) {
          answer.write(chunk);
          _updateStreamingAssistantStatus(
            translator.translateStatus(AgentStatusString.responding),
          );

          final now = DateTime.now();
          if (now.difference(lastStreamUiUpdate) >=
              const Duration(milliseconds: 120)) {
            lastStreamUiUpdate = now;
            _updateStreamingAssistant(answer.toString());
            _triggerScroll();
          }
        },
        onTrace: (event) {
          _updateStreamingAssistantStatus(translator.translateTrace(event));
          _appendTraceToAssistant(
            chatId: chatId,
            assistantCreatedAt: assistantMessage.createdAt,
            event: event,
          );
        },
        requestToolApproval: (request) {
          return _requestToolApproval(
            chatId: chatId,
            request: request,
            translator: translator,
          );
        },
      );
      if (_deletedGenerationChatIds.contains(chatId)) return;

      if (runResult is AiChatRunSuccess) {
        final currentChat = await _reconciledChatForRun(
          chatId: chatId,
          fallback: initialChat,
        );
        if (_deletedGenerationChatIds.contains(chatId)) return;
        final completedMessages = [...currentChat.messages];
        final assistantIndex = completedMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );

        final orchestrator = _runtimeFactory.createOrchestrator();

        if (assistantIndex >= 0) {
          final completedTraces = _ensureAgentRunSummaryTrace(
            completedMessages[assistantIndex].traces,
            runResult.finalOutcome,
            runStats: runResult.runStats,
          );
          final completion = orchestrator.finalizeAssistantTurn(
            initialChat: initialChat,
            assistantMessage: completedMessages[assistantIndex],
            answerText: runResult.answer,
            traces: completedTraces,
          );
          completedMessages[assistantIndex] = completion.assistantMessage
              .copyWith(
                promptTokens: runResult.runStats?.promptTokens,
                completionTokens: runResult.runStats?.completionTokens,
                totalTokens: runResult.runStats?.totalTokens,
                elapsedMs: runResult.runStats?.elapsedMs,
                tokenUsageEstimated: runResult.runStats == null
                    ? null
                    : !runResult.runStats!.usageFromProvider,
                promptCacheHitTokens: runResult.runStats?.promptCacheHitTokens,
                promptCacheMissTokens:
                    runResult.runStats?.promptCacheMissTokens,
                reasoningTokens: runResult.runStats?.reasoningTokens,
                agentRunId: runResult.runId,
              );
        }

        final latestAssistant = latestAssistantMessageForChat(
          currentChat.copyWith(messages: completedMessages),
        );
        final shouldExitPlanMode =
            initialChat.planMode &&
            latestAssistant?.todoSteps.isNotEmpty == true;
        final answeredChat = currentChat.copyWith(
          messages: completedMessages,
          updatedAt: DateTime.now(),
          planMode: shouldExitPlanMode ? false : currentChat.planMode,
        );

        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(answeredChat, activate: false);
        _sending = false;
        notifyListeners();
        await _storageService.saveAiChat(answeredChat);
        if (_deletedGenerationChatIds.contains(chatId)) {
          await _storageService.deleteAiChat(chatId);
          return;
        }

        await metricsRecorder.record(
          modelProfile: modelProfile,
          model: model,
          startedAt: assistantMessage.createdAt,
          finishedAt: DateTime.now(),
          runStats: runResult.runStats,
          ragHits: ragHits,
          success: runResult.succeeded,
          runId: runResult.runId,
        );
      } else if (runResult is AiChatRunCancelled) {
        AppLogService.instance.info(
          'LLM chat UI request cancelled',
          details: 'chatId=$chatId model=$model',
        );
        final currentChat = await _reconciledChatForRun(
          chatId: chatId,
          fallback: initialChat,
        );
        if (_deletedGenerationChatIds.contains(chatId)) return;
        final cancelledMessages = [...currentChat.messages];
        final assistantIndex = cancelledMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );
        final stopStr = translator.translateStatus(AgentStatusString.stopped);
        if (assistantIndex >= 0) {
          final stoppedText = runResult.partialAnswer.trim().isEmpty
              ? stopStr
              : '${runResult.partialAnswer}\n\n$stopStr';
          final traces = _ensureAgentRunSummaryTrace([
            ...cancelledMessages[assistantIndex].traces,
            AiMessageTrace.create(
              kind: 'approval',
              title: 'Stopped by user',
              content: stopStr,
            ),
          ], runResult.finalOutcome);
          cancelledMessages[assistantIndex] = cancelledMessages[assistantIndex]
              .copyWith(
                text: stoppedText,
                traces: traces,
                contextText: _contextTextForAssistant(
                  stoppedText,
                  traces: traces,
                ),
                agentRunId: runResult.runId,
              );
        }
        final cancelledChat = currentChat.copyWith(
          messages: cancelledMessages,
          updatedAt: DateTime.now(),
        );

        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(cancelledChat, activate: false);
        _sending = false;
        notifyListeners();
        await _storageService.saveAiChat(cancelledChat);
        if (_deletedGenerationChatIds.contains(chatId)) {
          await _storageService.deleteAiChat(chatId);
          return;
        }

        await metricsRecorder.record(
          modelProfile: modelProfile,
          model: model,
          startedAt: assistantMessage.createdAt,
          finishedAt: DateTime.now(),
          ragHits: ragHits,
          success: false,
          runId: runResult.runId,
        );
      } else if (runResult is AiChatRunFailed) {
        final currentChat = await _reconciledChatForRun(
          chatId: chatId,
          fallback: initialChat,
        );
        if (_deletedGenerationChatIds.contains(chatId)) return;
        final errorMessages = [...currentChat.messages];
        final assistantIndex = errorMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );
        AiMessageTrace? runSummaryTrace;
        if (assistantIndex >= 0) {
          final traces = _ensureAgentRunSummaryTrace(
            errorMessages[assistantIndex].traces,
            runResult.finalOutcome,
          );
          runSummaryTrace = traces.lastWhere(
            (trace) => trace.kind == 'agent_run_summary',
          );
          final partialText = runResult.partialAnswer;
          if (partialText.trim().isEmpty &&
              errorMessages[assistantIndex].text.isEmpty &&
              errorMessages[assistantIndex].todoSteps.isEmpty) {
            errorMessages.removeAt(assistantIndex);
          } else if (partialText.isNotEmpty) {
            errorMessages[assistantIndex] = errorMessages[assistantIndex]
                .copyWith(
                  text: partialText,
                  contextText: _contextTextForAssistant(
                    partialText,
                    traces: traces,
                  ),
                  traces: traces,
                  agentRunId: runResult.runId,
                );
          } else {
            errorMessages[assistantIndex] = errorMessages[assistantIndex]
                .copyWith(traces: traces, agentRunId: runResult.runId);
          }
        }
        final assistantOwnsRun = errorMessages.any(
          (message) => message.agentRunId == runResult.runId,
        );
        final errorChat = currentChat.copyWith(
          messages: [
            ...errorMessages,
            AiChatMessageRecord(
              role: 'error',
              text: translator.translateFailed(runResult.error),
              traces: assistantOwnsRun || runSummaryTrace == null
                  ? const []
                  : [runSummaryTrace],
              createdAt: DateTime.now(),
              agentRunId: assistantOwnsRun ? null : runResult.runId,
            ),
          ],
          updatedAt: DateTime.now(),
        );

        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(errorChat, activate: false);
        _sending = false;
        notifyListeners();
        await _storageService.saveAiChat(errorChat);
        if (_deletedGenerationChatIds.contains(chatId)) {
          await _storageService.deleteAiChat(chatId);
          return;
        }

        await metricsRecorder.record(
          modelProfile: modelProfile,
          model: model,
          startedAt: assistantMessage.createdAt,
          finishedAt: DateTime.now(),
          ragHits: ragHits,
          success: false,
          runId: runResult.runId,
        );
      }
    } catch (e, stackTrace) {
      if (!_deletedGenerationChatIds.contains(chatId)) {
        AppLogService.instance.error(
          'LLM chat UI request failed unexpectedly',
          error: e,
          stackTrace: stackTrace,
          details: 'chatId=$chatId model=$model',
        );
      }
    } finally {
      _clearStreamingAssistant(
        chatId: chatId,
        assistantCreatedAt: assistantMessage.createdAt,
      );
      _sending = false;
      if (_pendingApproval?.chatId == chatId) {
        _pendingApproval = null;
      }
      if (identical(_activeCancellationToken, cancellationToken)) {
        _activeCancellationToken = null;
      }
      if (_activeGenerationChatId == chatId) {
        _activeGenerationChatId = null;
      }
      _deletedGenerationChatIds.remove(chatId);
      notifyListeners();
      _triggerScroll();
    }
  }

  void notify() {
    notifyListeners();
  }

  void _beginStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required String status,
  }) {
    _streamingAssistantTarget = _StreamingAssistantTarget(
      chatId: chatId,
      assistantCreatedAt: assistantCreatedAt,
    );
    streamingAssistantText.value = '';
    streamingAssistantStatus.value = status;
  }

  void _updateStreamingAssistant(String text) {
    if (streamingAssistantText.value == text) return;
    streamingAssistantText.value = text;
  }

  void _updateStreamingAssistantStatus(String status) {
    if (_streamingAssistantTarget == null) return;
    if (streamingAssistantStatus.value == status) return;
    streamingAssistantStatus.value = status;
  }

  void _clearStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
  }) {
    final target = _streamingAssistantTarget;
    if (target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != assistantCreatedAt) {
      return;
    }
    _streamingAssistantTarget = null;
    streamingAssistantText.value = '';
    streamingAssistantStatus.value = '';
  }

  void _appendTraceToAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required LlmTraceEvent event,
  }) {
    final currentChat = _chatById(chatId);
    if (currentChat == null) return;
    final messages = [...currentChat.messages];
    final assistantIndex = messages.indexWhere(
      (message) =>
          message.role == 'assistant' &&
          message.createdAt == assistantCreatedAt,
    );
    if (assistantIndex < 0) return;
    messages[assistantIndex] = messages[assistantIndex].copyWith(
      traces: [
        ...messages[assistantIndex].traces,
        AiMessageTrace.create(
          kind: event.kind,
          title: _traceSecretPolicy.redactText(event.title),
          content: _traceSecretPolicy.redactJsonText(event.content),
        ),
      ],
    );
    _replaceChat(
      currentChat.copyWith(messages: messages, updatedAt: DateTime.now()),
      sort: false,
      activate: false,
    );
    notifyListeners();
    _triggerScroll();
  }

  List<AiMessageTrace> _ensureAgentRunSummaryTrace(
    List<AiMessageTrace> traces,
    String finalOutcome, {
    LlmRunStats? runStats,
  }) {
    for (final trace in traces.reversed) {
      if (trace.kind != 'agent_run_summary') continue;
      try {
        final decoded = jsonDecode(trace.content);
        if (decoded is Map &&
            '${decoded['finalOutcome'] ?? decoded['outcome'] ?? ''}'
                .trim()
                .isNotEmpty) {
          return List<AiMessageTrace>.from(traces, growable: false);
        }
      } catch (_) {
        continue;
      }
    }
    return [
      ...traces,
      AiMessageTrace.create(
        kind: 'agent_run_summary',
        title: 'Agent run summary',
        content: jsonEncode({
          'finalOutcome': finalOutcome,
          if (runStats != null) ...{
            'toolCalls': runStats.toolCalls,
            'approvalCount': runStats.approvalCount,
            'approvedCount': runStats.approvedCount,
            'elapsedMs': runStats.elapsedMs,
          },
        }),
      ),
    ];
  }

  bool _consumeContextCompression(String chatId) {
    return _pendingForceCompressionChats.remove(chatId);
  }

  // 内部辅助，从Slash命令提取
}
