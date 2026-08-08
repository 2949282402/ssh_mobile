import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:feature_playbook/feature_playbook.dart';
import '../services/ai_chat_status_translator.dart';
import '../services/ai_chat_run_metrics_recorder.dart';
import '../services/ai_chat_generation_runner.dart';
import '../services/ai_chat_run_state_reconciler.dart';

export '../services/ai_chat_status_translator.dart' show AgentStatusString;
import '../../../services/ai_tool_service.dart';
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
part 'ai_chat_viewmodel_history.dart';
part 'ai_chat_viewmodel_message_actions.dart';
part 'ai_chat_viewmodel_context.dart';
part 'ai_chat_viewmodel_generation.dart';
part 'ai_chat_viewmodel_streaming.dart';

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
  final PlaybookAutomationPort _playbookService;
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
    required PlaybookAutomationPort playbookService,
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
  void notify() {
    notifyListeners();
  }
}
