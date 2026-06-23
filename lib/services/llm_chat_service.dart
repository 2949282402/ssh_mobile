import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ai_tool_service.dart';
import 'agent_model_profile.dart';
import 'app_log_service.dart';
import 'app_settings.dart';
import 'multi_agent_coordinator.dart';
import 'storage_service.dart';
import 'tool_exposure_router.dart';
import 'tool_secret_policy.dart';
import 'agent/plan_execution_controller.dart';
import 'package:uuid/uuid.dart';
import 'llm_runtime/llm_runtime_types.dart';
import 'llm_provider/llm_provider_types.dart';
import 'llm_provider/llm_provider_adapter.dart';
import 'llm_provider/llm_provider_factory.dart';
import 'llm_provider/llm_url_utils.dart';

part 'llm_chat/llm_chat_types.dart';
part 'llm_chat/llm_system_prompt.dart';
part 'llm_chat/llm_context_compressor.dart';
part 'llm_chat/llm_chat_utils.dart';
part 'llm_chat/llm_safety_auditor.dart';
part 'llm_chat/llm_stream_handler.dart';
part 'llm_chat/tool_loop_controller.dart';
part 'llm_chat/tool_result_classifier.dart';
part 'llm_chat/plan_output_validator.dart';

abstract interface class LlmClientAdapter {
  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  });

  Future<String> send({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    String? runId,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool planMode = false,
    AiChatMessageRecord? approvedPlanMessage,
  });

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
  });
}

/// OpenAI ?? LLM ???????
class LlmChatService implements LlmClientAdapter {

  final StorageService storageService;
  final AiToolExecutor toolService;
  final MultiAgentCoordinatorAdapter multiAgentCoordinator;
  final ToolExposureRouter toolExposureRouter;
  final AppLanguage language;
  final bool useCustomPrompts;
  final String customSystemPrompt;
  final String customPlannerPrompt;
  final String customOperatorPrompt;
  final String customExplorePrompt;
  final String customReviewerPrompt;
  final String customSummarizerPrompt;
  final String customCoordinatorPrompt;
  final ToolSecretPolicy _toolSecretPolicy = const ToolSecretPolicy();

  LlmChatService({
    required this.storageService,
    required this.toolService,
    this.language = AppLanguage.zh,
    this.useCustomPrompts = false,
    this.customSystemPrompt = '',
    this.customPlannerPrompt = '',
    this.customOperatorPrompt = '',
    this.customExplorePrompt = '',
    this.customReviewerPrompt = '',
    this.customSummarizerPrompt = '',
    this.customCoordinatorPrompt = '',
    MultiAgentCoordinatorAdapter? multiAgentCoordinator,
    ToolExposureRouter? toolExposureRouter,
  })  : multiAgentCoordinator =
            multiAgentCoordinator ?? const MultiAgentCoordinator(),
        toolExposureRouter = toolExposureRouter ?? const ToolExposureRouter();

  String get systemPrompt {
    return systemPromptFor(planMode: false);
  }

  @visibleForTesting
  List<AiTool> filterVisibleTools(
    Iterable<AiTool> tools, {
    Set<String>? allowedTools,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    bool planMode = false,
  }) {
    return toolExposureRouter
        .selectTools(
          tools,
          context: ToolExposureContext(
            userRequest: userRequest,
            planMode: planMode,
            hasWebViewSession: hasWebViewSession,
            hasApprovedPlan: hasApprovedPlan,
            selectedConnectionIds: selectedConnectionIds,
            allowedTools: allowedTools,
          ),
        )
        .tools;
  }

  @visibleForTesting
  Future<List<Map<String, dynamic>>> visibleToolDefinitions({
    Set<String>? allowedTools,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    bool planMode = false,
  }) async {
    final tools = await toolService.tools();
    return filterVisibleTools(
      tools,
      allowedTools: allowedTools,
      userRequest: userRequest,
      selectedConnectionIds: selectedConnectionIds,
      hasWebViewSession: hasWebViewSession,
      hasApprovedPlan: hasApprovedPlan,
      planMode: planMode,
    ).map((tool) => tool.definition).toList(growable: false);
  }

  String systemPromptFor({bool planMode = false}) {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn ? systemPromptEnPersona : systemPromptZhPersona;
    final baseSafety = isEn ? systemPromptEnSafety : systemPromptZhSafety;

    final persona = (useCustomPrompts && customSystemPrompt.trim().isNotEmpty)
        ? customSystemPrompt.trim()
        : basePersona.trim();

    final base = '$persona\n\n$baseSafety';
    if (!planMode) return base;

    final planInstructions = isEn
        ? '\n\n[PLAN MODE ACTIVE]\n'
            'You are currently in PLAN MODE. Your goal is to design a detailed, step-by-step operation plan for the user\'s request.\n'
            '1. Restrictions: DO NOT call any state-changing tools or run mutating shell commands. Only recommend commands and describe expected outcomes.\n'
            '2. Tool availability: In Plan Mode you may use read-only tools, plan-only tools such as client_task_create, and the plan control tool client_set_plan_mode when applicable. Execution-only tools such as client_task_update are unavailable until execution mode.\n'
            '3. Plan persistence: The app can persist executable todoSteps either from client_task_create calls or by parsing a valid ```playbook JSON block from your final reply. That block is only a chat-plan persistence format for todoSteps; it does not create a saved reusable Playbook record. If you do not call client_task_create, you must still return a valid ```playbook JSON block.\n'
            '   - Default behavior: For ordinary requests, keep the work as a chat-bound execution plan. Only use saved-playbook tools when the user explicitly asks to save, reuse, manage, or run a reusable playbook/script.\n'
            '4. Output Format: You must structure your final answer with a clear implementation plan containing:\n'
            '   - **Context**: Summary of current state and diagnostics.\n'
            '   - **Proposal**: Step-by-step tasks. Wrap the structured steps in a markdown JSON block ```playbook ... ```. The app uses this marker only to parse and persist chat todoSteps, not to save a reusable Playbook record:\n'
            '     {\n'
            '       "name": "Plan Name",\n'
            '       "description": "Brief description",\n'
            '       "steps": [\n'
            '         {"name": "Step 1 Title", "command": "command", "description": "What to do", "connectionId": "optional-server-id"}\n'
            '       ]\n'
            '     }\n'
            '   - **Verification**: How to verify the plan succeeded.\n'
            '5. Execution handoff: Once the user approves the plan, execute the persisted steps sequentially and call client_task_update with status running, success, failed, or skipped. The legacy alias in_progress may still appear in old prompts or histories, but running is the canonical status.'
        : '\n\n?????????\n'
            '????????????????????????????????????????????\n'
            '1. ????????????????????????? sftp_write_text, playbook_execute ???????????? shell ??????????????????\n'
            '2. ?????????????????????????\n'
            '   - **??? (Context)**: ????????????\n'
            '   - **???? (Proposal)**: ????????????????????? markdown JSON ??? ```playbook ... ``` ????????????????????? TODO ??????????????????\n'
            '     {\n'
            '       "name": "????",\n'
            '       "description": "????",\n'
            '       "steps": [\n'
            '         {"name": "?? 1 ??", "command": "????", "description": "????"}\n'
            '       ]\n'
            '     }\n'
            '   - **?? (Verification)**: ??????????????';
    final normalizedPlanInstructions = isEn
        ? planInstructions
        : '\n\n[PLAN MODE ACTIVE]\n'
            '????????????????????????????????????\n'
            '1. ????????? state-changing ?????????????? shell ?????????????????\n'
            '2. ??????????????????plan-only ???? client_task_create??????????execution-only ???? client_task_update??????????\n'
            '3. ??????????????????? todoSteps????? client_task_create?????????????? ```playbook JSON ??????????????????????????????????? Playbook?????? client_task_create????????? ```playbook JSON?\n'
            '   - ???????????????????????????????????????????????/??????? Playbook ?????\n'
            '4. ?????????????????????\n'
            '   - Context???????????\n'
            '   - Proposal??????????????????? ```playbook ... ``` JSON ???????????????????? todoSteps???????? Playbook?\n'
            '     {\n'
            '       "name": "????",\n'
            '       "description": "????",\n'
            '       "steps": [\n'
            '         {"name": "?? 1", "command": "??", "description": "??", "connectionId": "????? ID"}\n'
            '       ]\n'
            '     }\n'
            '   - Verification??????????\n'
            '5. ????????????????????????????? client_task_update ?????? running?success?failed ? skipped?????????? in_progress??????? running?';
    return '$base$normalizedPlanInstructions';
  }

  String get compressionPrompt {
    return language == AppLanguage.en
        ? 'Summarize this conversation for continuing an SSH/SFTP assistant chat. Preserve server names, paths, commands, decisions, approvals, errors, and unresolved tasks. Be concise but operationally complete.'
        : '?????????? SSH/SFTP ?????????????????????????????????????????????????';
  }

  String get conversationMemorySummaryHeader {
    return language == AppLanguage.en
        ? 'Conversation memory summary:\n'
        : '?????????\n';
  }

  String get plannerPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn
        ? multiAgentPlannerPromptEnPersona
        : multiAgentPlannerPromptZhPersona;
    final baseSafety = isEn
        ? multiAgentPlannerPromptEnSafety
        : multiAgentPlannerPromptZhSafety;

    final persona = (useCustomPrompts && customPlannerPrompt.trim().isNotEmpty)
        ? customPlannerPrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get operatorPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn
        ? multiAgentOperatorPromptEnPersona
        : multiAgentOperatorPromptZhPersona;
    final baseSafety = isEn
        ? multiAgentOperatorPromptEnSafety
        : multiAgentOperatorPromptZhSafety;

    final persona = (useCustomPrompts && customOperatorPrompt.trim().isNotEmpty)
        ? customOperatorPrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get explorePrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn
        ? multiAgentExplorePromptEnPersona
        : multiAgentExplorePromptZhPersona;
    final baseSafety = isEn
        ? multiAgentExplorePromptEnSafety
        : multiAgentExplorePromptZhSafety;

    final persona = (useCustomPrompts && customExplorePrompt.trim().isNotEmpty)
        ? customExplorePrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get reviewerPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn
        ? multiAgentReviewerPromptEnPersona
        : multiAgentReviewerPromptZhPersona;
    final baseSafety = isEn
        ? multiAgentReviewerPromptEnSafety
        : multiAgentReviewerPromptZhSafety;

    final persona = (useCustomPrompts && customReviewerPrompt.trim().isNotEmpty)
        ? customReviewerPrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get summarizerPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn
        ? multiAgentSummarizerPromptEnPersona
        : multiAgentSummarizerPromptZhPersona;
    final baseSafety = isEn
        ? multiAgentSummarizerPromptEnSafety
        : multiAgentSummarizerPromptZhSafety;

    final persona =
        (useCustomPrompts && customSummarizerPrompt.trim().isNotEmpty)
            ? customSummarizerPrompt.trim()
            : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get coordinatorPrompt {
    return language == AppLanguage.en
        ? multiAgentCoordinatorPromptEn
        : multiAgentCoordinatorPromptZh;
  }

  @override
  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  }) async {
    final settings = await storageService.loadAiConnectionSettings();
    final provider = LlmProviderFactory.fromSettings(settings);
    final resolvedApiKey = apiKey?.trim().isNotEmpty == true
        ? apiKey!.trim()
        : await storageService.getAiApiKey();
    return provider.fetchModels(
      baseUrl: baseUrl,
      apiKey: resolvedApiKey,
    );
  }

  @override
  Future<String> send({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    String? runId,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool planMode = false,
    AiChatMessageRecord? approvedPlanMessage,
  }) {
    return _sendImpl(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
      runId: runId,
      userRequest: userRequest,
      selectedConnectionIds: selectedConnectionIds,
      hasWebViewSession: hasWebViewSession,
      hasApprovedPlan: hasApprovedPlan,
      memorySources: memorySources,
      planMode: planMode,
      approvedPlanMessage: approvedPlanMessage,
    );
  }

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
    return _streamImpl(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
      runId: runId,
      allowedTools: allowedTools,
      userRequest: userRequest,
      selectedConnectionIds: selectedConnectionIds,
      hasWebViewSession: hasWebViewSession,
      hasApprovedPlan: hasApprovedPlan,
      memorySources: memorySources,
      forceContextCompression: forceContextCompression,
      planMode: planMode,
      approvedPlanMessage: approvedPlanMessage,
    );
  }

  static int estimateMessagesTokens(List<Map<String, dynamic>> messages) {
    var total = 0;
    for (final message in messages) {
      total += 4;
      total += estimateTextTokens('${message['role'] ?? ''}');
      total += estimateTextTokens('${message['content'] ?? ''}');
    }
    return total;
  }

  static int estimateTextTokens(String text) {
    if (text.isEmpty) return 0;
    var asciiRunes = 0;
    var nonAsciiRunes = 0;
    for (final rune in text.runes) {
      if (rune <= 0x7f) {
        asciiRunes++;
      } else {
        nonAsciiRunes++;
      }
    }
    return (asciiRunes / 4).ceil() + nonAsciiRunes;
  }

  static String resolveOpenAiCompatibleUrl(String baseUrl, String path) {
    return LlmUrlUtils.resolveOpenAiCompatibleUrl(baseUrl, path);
  }

  static bool looksLikeToolUnsupportedError(String body) {
    return LlmUrlUtils.looksLikeToolUnsupportedError(body);
  }
}



