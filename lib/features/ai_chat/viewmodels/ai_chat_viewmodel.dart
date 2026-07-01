import 'dart:async';

import 'package:flutter/foundation.dart';
import '../services/ai_chat_status_translator.dart';
import '../services/ai_chat_run_metrics_recorder.dart';
import '../services/ai_chat_generation_runner.dart';

export '../services/ai_chat_status_translator.dart' show AgentStatusString;
import '../../../services/ai_tool_service.dart';
import '../../playbook/models/playbook.dart';
import '../../../services/agent_model_profile.dart';
import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../services/ai_chat_runtime_factory.dart';
import '../services/ai_chat_context_builder.dart';
import '../services/ai_chat_message_mapper.dart';
import '../services/ai_chat_token_estimator.dart';
import '../../../services/llm_chat_service.dart';
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
    final normalizedFetched = fetchedModels
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
  bool _historyLoadStarted = false;
  bool _historyLoading = false;
  bool _sending = false;
  bool _toolsExpanded = false;

  // 选中的连接和工具权限
  final Set<String> _selectedConnectionIds = {};
  final Map<String, Set<String>> _chatAllowedTools = {};
  final Set<String> _pendingForceCompressionChats = {};
  final List<AiChatAttachment> _pendingAttachments = [];

  // 工具审批
  PendingToolApproval? _pendingApproval;
  LlmCancellationToken? _activeCancellationToken;
  ClientRuntimeHealthReport? _lastRuntimeHealthReport;

  // 上下文限制
  int _contextWindowTokens = AiContextWindowSize.k259;

  // 流式输出ValueNotifier
  final ValueNotifier<String> streamingAssistantText =
      ValueNotifier<String>('');
  final ValueNotifier<String> streamingAssistantStatus =
      ValueNotifier<String>('');
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
  })  : _storageService = storageService,
        _playbookService = playbookService,
        _appSettings = appSettings,
        _runtimeFactory = runtimeFactory ??
            AiChatRuntimeFactory(
              storageService: storageService,
              sshService: sshService,
              sftpService: sftpService,
              performanceMonitorService: performanceMonitorService,
              playbookService: playbookService,
              ragService: ragService,
              appSettings: appSettings,
            ),
        _clientHealthAdvisor = clientHealthAdvisor ??
            ClientHealthAdvisor(
              clientSystemToolService: ClientSystemToolService.instance,
            ) {
    final resolvedContextBuilder =
        contextBuilder ?? const AiChatContextBuilder();
    final resolvedMessageMapper = messageMapper ??
        AiChatMessageMapper(contextBuilder: resolvedContextBuilder);

    _contextBuilder = resolvedContextBuilder;
    _messageMapper = resolvedMessageMapper;
    _tokenEstimator = tokenEstimator ??
        AiChatTokenEstimator(messageMapper: resolvedMessageMapper);
  }

  // Getters
  List<AiChatRecord> get chats => _chats;
  List<AiChatRecord> get savedHistoryChats => _savedHistoryChats;
  String? get activeChatId => _activeChatId;
  bool get loading => _loading;
  bool get historyLoading => _historyLoading;
  bool get sending => _sending;
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
    final settings = await _storageService.loadAiConnectionSettings();
    final draft = _newChatRecord(settings.model);
    _chats = [draft];
    _activeChatId = draft.id;
    _contextWindowTokens = settings.contextWindowTokens;
    _loading = false;
    notifyListeners();
  }

  // 加载历史记录
  Future<void> loadHistoryChatsIfNeeded() async {
    if (_historyLoadStarted || _historyLoading) return;
    _historyLoading = true;
    notifyListeners();

    final chats = await _storageService.loadAiChats();
    _historyLoadStarted = true;
    _historyLoading = false;
    _savedHistoryChats = chats;

    final drafts = _chats.where((chat) => chat.messages.isEmpty).toList();
    final draftIds = drafts.map((chat) => chat.id).toSet();
    _chats = [
      ...drafts,
      ...chats.where((chat) => !draftIds.contains(chat.id)),
    ];
    _activeChatId ??= _chats.isEmpty ? null : _chats.first.id;
    notifyListeners();
  }

  // 创建/切换/删除会话
  Future<void> createChatFromSettings() async {
    final settings = await _storageService.loadAiConnectionSettings();
    createChat(settings.model);
  }

  void createChat(String model) {
    final chat = _newChatRecord(model);
    _chats = [
      chat,
      ..._chats.where((item) => item.messages.isNotEmpty),
    ];
    _activeChatId = chat.id;
    notifyListeners();
    _triggerScroll();
  }

  void selectChat(String id) {
    if (_activeChatId == id) return;
    _activeChatId = id;
    notifyListeners();
    _triggerScroll();
  }

  Future<void> deleteChat(String id) async {
    if (_chats.isEmpty && _savedHistoryChats.isEmpty) return;
    final deleted = _chatById(id);
    _chatAllowedTools.remove(id);
    _pendingForceCompressionChats.remove(id);
    final nextChats = _chats.where((chat) => chat.id != id).toList();
    if (nextChats.isEmpty) {
      final settings = await _storageService.loadAiConnectionSettings();
      nextChats.add(_newChatRecord(settings.model));
    }
    _chats = nextChats;
    _savedHistoryChats =
        _savedHistoryChats.where((chat) => chat.id != id).toList();
    if (_activeChatId == id || _activeChatId == null) {
      _activeChatId = nextChats.first.id;
    }
    notifyListeners();
    if (deleted?.messages.isNotEmpty == true) {
      await _storageService.deleteAiChat(id);
    }
    ClientWebViewService.instance.clearSession(id);
    _triggerScroll();
  }

  Future<void> updateActiveChat(AiChatRecord chat) async {
    _replaceChat(chat);
    notifyListeners();
    await _storageService.saveAiChat(chat);
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
    final cachedModels =
        await _storageService.loadCachedAiModels(baseUrl: settings.baseUrl);
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
          'baseUrl=${settings.baseUrl} model=${settings.model} hasApiKey=${settings.hasApiKey}',
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
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM settings save failed',
        error: e,
        stackTrace: stackTrace,
        details: 'baseUrl=$baseUrl model=$model',
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
    _chatAllowedTools[chatId] = allowedTools;
    notifyListeners();
  }

  // 发送逻辑
  Future<SendTextResult> sendText({
    required String text,
    AiApprovedPlanRef? approvedPlanRef,
  }) async {
    var activeChat = this.activeChat;
    if (text.isEmpty) return const SendTextEmptyText();
    if (_sending) return const SendTextAlreadySending();
    if (activeChat == null) return const SendTextNoActiveChat();

    var targetText = text.trim();
    if (targetText.startsWith('/')) {
      final parts = targetText.split(' ');
      final cmd = parts[0].toLowerCase();
      final args = parts.sublist(1).join(' ').trim();
      if (cmd == '/plan' && args.isNotEmpty) {
        final updated = activeChat.copyWith(
          planMode: true,
          updatedAt: DateTime.now(),
        );
        _replaceChat(updated);
        notifyListeners();
        await _storageService.saveAiChat(updated);

        activeChat = updated;
        targetText = args;
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

    final settings = await _storageService.loadAiConnectionSettings();
    final currentModel = settings.model.trim();
    if (!settings.hasApiKey) {
      AppLogService.instance.warning(
        'LLM chat blocked: API key missing or invalid',
        details: 'model=$currentModel',
      );
      return const SendTextApiKeyMissing();
    }

    _sending = true;
    final chatId = activeChat.id;
    final now = DateTime.now();

    // RAG 检索
    final attachments = List<AiChatAttachment>.from(_pendingAttachments);
    final orchestrator = _runtimeFactory.createOrchestrator();

    final preparedTurn = await orchestrator.prepareTurn(
      chat: activeChat,
      text: targetText,
      createdAt: now,
      language: _appSettings.language,
      attachments: attachments,
      selectedConnectionIds: _selectedConnectionIds,
      approvedPlanRef: approvedPlanRef,
      ragEnabled: _appSettings.ragEnabled,
    );
    final userMessage = preparedTurn.userMessage;
    final ragChunks = const <RagChunk>[];

    // RAG Traces
    final assistantTraces =
        List<AiMessageTrace>.from(preparedTurn.assistantMessage.traces);
    if (ragChunks.isNotEmpty) {
      final traceContent = StringBuffer();
      final isEn = _appSettings.isEnglish;
      for (final chunk in ragChunks) {
        traceContent.writeln(isEn
            ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
            : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})');
        traceContent.writeln('---');
        traceContent.writeln(chunk.text);
        traceContent.writeln('========================================\n');
      }
      assistantTraces.add(AiMessageTrace(
        id: 'rag-${now.microsecondsSinceEpoch}',
        kind: 'rag_context',
        title: isEn ? 'Knowledge Base Retrieval (RAG)' : '知识库检索 (RAG)',
        content: traceContent.toString(),
        createdAt: now,
      ));
    }

    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      traces: assistantTraces,
      createdAt: now,
    );
    final nextMessages = [
      ...activeChat.messages,
      userMessage,
      assistantMessage,
    ];
    final nextChat = activeChat.copyWith(
      title: activeChat.messages.isEmpty ? _titleFrom(targetText) : null,
      model: currentModel.isNotEmpty ? currentModel : activeChat.model,
      messages: nextMessages,
      updatedAt: now,
      approvedPlan: approvedPlanRef,
    );

    _replaceChat(nextChat);
    _pendingAttachments.clear();
    _toolsExpanded = false;
    notifyListeners();
    _triggerScroll();

    await _storageService.saveAiChat(nextChat);

    unawaited(_generateAssistantResponse(
      chatId: chatId,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: currentModel.isNotEmpty ? currentModel : nextChat.model,
      requestMessages: nextMessages,
      userRequest: targetText,
      memorySources: preparedTurn.memorySources,
      ragHits: preparedTurn.ragHits,
    ));

    return const SendTextSuccess();
  }

  Future<ApprovePlanExecutionResult> approvePlanAndExecute(
    DateTime assistantCreatedAt, {
    bool forceAfterWarning = false,
  }) async {
    if (_sending) return const ApprovePlanExecutionAlreadySending();
    final activeChat = this.activeChat;
    if (activeChat == null) return const ApprovePlanExecutionNoPlan();
    final planMessage =
        chatAssistantMessageByCreatedAt(activeChat, assistantCreatedAt);
    if (planMessage == null || planMessage.todoSteps.isEmpty) {
      return const ApprovePlanExecutionNoPlan();
    }

    final healthReport = await _clientHealthAdvisor.check(
      profile: ClientHealthCheckProfile.agentExecution,
    );
    _lastRuntimeHealthReport = healthReport;
    notifyListeners();
    if (healthReport.status == ClientRuntimeHealthStatus.blocking) {
      return ApprovePlanExecutionBlocked(healthReport);
    }
    if (healthReport.status == ClientRuntimeHealthStatus.warning &&
        !forceAfterWarning) {
      return ApprovePlanExecutionWarning(healthReport);
    }

    final approvedAt = DateTime.now();
    final approvedPlan = AiApprovedPlanRef(
      assistantCreatedAt: assistantCreatedAt,
      approvedAt: approvedAt,
    );
    final updatedChat = activeChat.copyWith(
      planMode: false,
      approvedPlan: approvedPlan,
      updatedAt: approvedAt,
    );
    _replaceChat(updatedChat);
    notifyListeners();
    await _storageService.saveAiChat(updatedChat);

    final isEn = _appSettings.language == AppLanguage.en;
    await sendText(
      text: isEn ? 'Execute the approved plan.' : '执行已批准的计划。',
      approvedPlanRef: approvedPlan,
    );
    return ApprovePlanExecutionStarted(healthReport: healthReport);
  }

  Future<void> retryTodoStep(String taskId) async {
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
      _replaceChat(updated, sort: false);
      notifyListeners();
      await _storageService.saveAiChat(updated);
    }
  }

  Future<void> skipTodoStep(String taskId, String reason) async {
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
      _replaceChat(updated, sort: false);
      notifyListeners();
      await _storageService.saveAiChat(updated);
    }
  }

  void stopGeneration() {
    if (!_sending) return;
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
    final activeChat = this.activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'assistant') return;

    final settings = await _storageService.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      return;
    }

    final prefix = activeChat.messages.take(messageIndex).toList();
    if (prefix.where((message) => message.role == 'user').isEmpty) return;
    final now = DateTime.now();
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [...prefix, assistantMessage];
    final nextModel =
        settings.model.trim().isNotEmpty ? settings.model : activeChat.model;
    final nextChat = activeChat.copyWith(
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    _replaceChat(nextChat);
    _sending = true;
    notifyListeners();
    _triggerScroll();

    await _storageService.saveAiChat(nextChat);

    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: prefix.lastWhere((message) => message.role == 'user').text,
      memorySources: const [],
      ragHits: 0,
    );
  }

  Future<void> editUserMessage(
      int messageIndex, String trimmedEditedText) async {
    final activeChat = this.activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'user') return;
    if (trimmedEditedText.isEmpty) return;

    final targetIndex = activeChat.messages.indexWhere(
      (message) =>
          message.role == 'user' && message.createdAt == target.createdAt,
    );
    if (targetIndex < 0 || targetIndex >= activeChat.messages.length) {
      return;
    }

    final settings = await _storageService.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      return;
    }

    final currentTarget = activeChat.messages[targetIndex];
    if (currentTarget.role != 'user') return;

    final now = DateTime.now();
    final editedUser = currentTarget.copyWith(
      text: trimmedEditedText,
      createdAt: now,
    );
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [
      ...activeChat.messages.take(targetIndex),
      editedUser,
      assistantMessage,
    ];
    final nextModel =
        settings.model.trim().isNotEmpty ? settings.model : activeChat.model;
    final nextChat = activeChat.copyWith(
      title: targetIndex == 0 ? _titleFrom(trimmedEditedText) : null,
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    _replaceChat(nextChat);
    _sending = true;
    notifyListeners();
    _triggerScroll();

    await _storageService.saveAiChat(nextChat);

    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      userRequest: trimmedEditedText,
      memorySources: const [],
      ragHits: 0,
    );
  }

  void branchFromAssistant(int messageIndex) {
    final activeChat = this.activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
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

    _chats = [branch, ..._chats];
    if (branch.messages.isNotEmpty) {
      _savedHistoryChats = [branch, ..._savedHistoryChats];
      _historyLoadStarted = true;
    }
    _activeChatId = branch.id;
    notifyListeners();

    _storageService.saveAiChat(branch);
    _triggerScroll();
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
        selected.add(AiChatSelectedConnectionContext(
          id: conn.id,
          name: conn.name,
          username: conn.username,
          host: conn.host,
          port: conn.port,
        ));
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

  void _replaceChat(AiChatRecord chat, {bool sort = true}) {
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
    _activeChatId = chat.id;
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
    return _messageMapper.messagesForRequest(messages,
        placeholder: placeholder);
  }

  static List<Map<String, dynamic>> buildMultipartContent(
    String textContent,
    List<AiChatAttachment> attachments,
  ) {
    return AiChatMessageMapper.buildMultipartContent(textContent, attachments);
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
  }) async {
    final settings = await _storageService.loadAiConnectionSettings();
    final modelProfile = AgentModelProfile(
      mainModel: model,
      helperModel: settings.helperModel,
      auditModel: settings.auditModel,
      fallbackPolicy: settings.modelFallbackPolicy,
    );

    final translator = AiChatStatusTranslator(_appSettings.language);
    final metricsRecorder = AiChatRunMetricsRecorder(_storageService);
    final runner = AiChatGenerationRunner(runtimeFactory: _runtimeFactory);

    final cancellationToken = LlmCancellationToken();
    _activeCancellationToken = cancellationToken;
    final answer = StringBuffer();
    final forceContextCompression = _consumeContextCompression(chatId);
    final allowedTools = _chatAllowedTools[chatId];

    _beginStreamingAssistant(
      chatId: chatId,
      assistantCreatedAt: assistantMessage.createdAt,
      status: translator.translateStatus(AgentStatusString.preparing),
    );

    try {
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
        selectedConnectionIds: _selectedConnectionIds,
        requestMessagesJson: _messagesForRequest(
          requestMessages,
          placeholder: assistantMessage,
        ),
        onTextChunk: (chunk) {
          answer.write(chunk);
          _updateStreamingAssistantStatus(
              translator.translateStatus(AgentStatusString.responding));

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

      if (runResult is AiChatRunSuccess) {
        final currentChat = _chatById(chatId) ?? initialChat;
        final completedMessages = [...currentChat.messages];
        final assistantIndex = completedMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );

        final orchestrator = _runtimeFactory.createOrchestrator();

        if (assistantIndex >= 0) {
          final completion = orchestrator.finalizeAssistantTurn(
            initialChat: initialChat,
            assistantMessage: completedMessages[assistantIndex],
            answerText: runResult.answer,
            traces: [...completedMessages[assistantIndex].traces],
          );
          completedMessages[assistantIndex] =
              completion.assistantMessage.copyWith(
            promptTokens: runResult.runStats?.promptTokens,
            completionTokens: runResult.runStats?.completionTokens,
            totalTokens: runResult.runStats?.totalTokens,
            elapsedMs: runResult.runStats?.elapsedMs,
            tokenUsageEstimated: runResult.runStats == null
                ? null
                : !runResult.runStats!.usageFromProvider,
            promptCacheHitTokens: runResult.runStats?.promptCacheHitTokens,
            promptCacheMissTokens: runResult.runStats?.promptCacheMissTokens,
            reasoningTokens: runResult.runStats?.reasoningTokens,
            agentRunId: runResult.runId,
          );
        }

        final latestAssistant = latestAssistantMessageForChat(
          currentChat.copyWith(messages: completedMessages),
        );
        final shouldExitPlanMode = initialChat.planMode &&
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
        _replaceChat(answeredChat);
        _sending = false;
        notifyListeners();
        await _storageService.saveAiChat(answeredChat);

        await metricsRecorder.record(
          modelProfile: modelProfile,
          model: model,
          startedAt: assistantMessage.createdAt,
          finishedAt: DateTime.now(),
          runStats: runResult.runStats,
          ragHits: ragHits,
          success: true,
          runId: runResult.runId,
        );
      } else if (runResult is AiChatRunCancelled) {
        AppLogService.instance.info(
          'LLM chat UI request cancelled',
          details: 'chatId=$chatId model=$model',
        );
        final currentChat = _chatById(chatId) ?? initialChat;
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
          final traces = [
            ...cancelledMessages[assistantIndex].traces,
            AiMessageTrace.create(
              kind: 'approval',
              title: 'Stopped by user',
              content: stopStr,
            ),
          ];
          cancelledMessages[assistantIndex] =
              cancelledMessages[assistantIndex].copyWith(
            text: stoppedText,
            traces: traces,
            contextText: _contextTextForAssistant(stoppedText, traces: traces),
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
        _replaceChat(cancelledChat);
        _sending = false;
        notifyListeners();
        await _storageService.saveAiChat(cancelledChat);

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
        final currentChat = _chatById(chatId) ?? initialChat;
        final errorMessages = [...currentChat.messages];
        final assistantIndex = errorMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );
        if (assistantIndex >= 0) {
          final partialText = runResult.partialAnswer;
          if (partialText.trim().isEmpty &&
              errorMessages[assistantIndex].text.isEmpty) {
            errorMessages.removeAt(assistantIndex);
          } else if (partialText.isNotEmpty) {
            errorMessages[assistantIndex] =
                errorMessages[assistantIndex].copyWith(
              text: partialText,
              contextText: _contextTextForAssistant(
                partialText,
                traces: errorMessages[assistantIndex].traces,
              ),
              agentRunId: runResult.runId,
            );
          } else {
            errorMessages[assistantIndex] =
                errorMessages[assistantIndex].copyWith(
              agentRunId: runResult.runId,
            );
          }
        }
        final errorChat = currentChat.copyWith(
          messages: [
            ...errorMessages,
            AiChatMessageRecord(
              role: 'error',
              text: translator.translateFailed(runResult.error),
              createdAt: DateTime.now(),
              agentRunId: runResult.runId,
            ),
          ],
          updatedAt: DateTime.now(),
        );

        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(errorChat);
        _sending = false;
        notifyListeners();
        await _storageService.saveAiChat(errorChat);

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
      AppLogService.instance.error(
        'LLM chat UI request failed unexpectedly',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=$chatId model=$model',
      );
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
      currentChat.copyWith(
        messages: messages,
        updatedAt: DateTime.now(),
      ),
      sort: false,
    );
    notifyListeners();
    _triggerScroll();
  }

  bool _consumeContextCompression(String chatId) {
    return _pendingForceCompressionChats.remove(chatId);
  }

  // 内部辅助，从Slash命令提取
}
