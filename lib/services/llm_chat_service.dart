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
import 'llm_provider/llm_provider_types.dart';
import 'llm_provider/llm_provider_adapter.dart';
import 'llm_provider/llm_provider_factory.dart';
import 'llm_provider/openai_chat_provider.dart';

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

/// OpenAI 兼容 LLM 流式对话服务。
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
        : '\n\n【规划模式已激活】\n'
            '你当前处于“规划模式”。你的目标是针对用户的运维请求设计一份详细的、分步的操作执行计划。\n'
            '1. 行为限制：绝对不能调用任何会改变系统状态的工具（如 sftp_write_text, playbook_execute 等）或执行有修改副作用的 shell 命令。仅提供只读建议并描述预期效果。\n'
            '2. 输出格式：你必须用以下清晰的结构输出你的规划建议：\n'
            '   - **上下文 (Context)**: 现状汇总与系统诊断事实。\n'
            '   - **方案建议 (Proposal)**: 详细的分步步骤。将这些步骤包裹在一个标准的 markdown JSON 代码块 ```playbook ... ``` 中。这个标记仅用于让应用解析并持久化聊天内 TODO 任务，并不代表自动保存成可复用剧本：\n'
            '     {\n'
            '       "name": "计划名称",\n'
            '       "description": "简要描述",\n'
            '       "steps": [\n'
            '         {"name": "步骤 1 名称", "command": "命令内容", "description": "操作说明"}\n'
            '       ]\n'
            '     }\n'
            '   - **验证 (Verification)**: 运维步骤完成后如何验证成功。';
    final normalizedPlanInstructions = isEn
        ? planInstructions
        : '\n\n[PLAN MODE ACTIVE]\n'
            '你当前处于规划模式。目标是为用户请求产出一份详细、可执行、分步骤的计划。\n'
            '1. 限制：不要调用任何 state-changing 工具，也不要执行会修改状态的 shell 命令；只能做只读诊断、分析和规划。\n'
            '2. 工具语义：规划模式下只允许只读工具、plan-only 工具（如 client_task_create）以及计划控制工具；execution-only 工具（如 client_task_update）在规划阶段不可用。\n'
            '3. 计划持久化：应用可以通过两种方式持久化 todoSteps：一是调用 client_task_create，二是解析你最终回复里的合法 ```playbook JSON 代码块。这个代码块只是聊天计划的持久化格式，不会自动创建已保存的可复用 Playbook。即使不调用 client_task_create，也必须返回合法的 ```playbook JSON。\n'
            '   - 默认行为：普通请求一律先制定聊天内执行计划。只有当用户明确要求保存、复用、管理或运行可复用剧本/脚本时，才使用 Playbook 相关工具。\n'
            '4. 输出格式：最终答案必须包含清晰的计划结构：\n'
            '   - Context：当前状态与诊断结论。\n'
            '   - Proposal：分步骤执行方案。必须把结构化步骤包在 ```playbook ... ``` JSON 代码块中，便于应用后续解析并持久化聊天内 todoSteps，而不是保存独立 Playbook：\n'
            '     {\n'
            '       "name": "计划名称",\n'
            '       "description": "简要说明",\n'
            '       "steps": [\n'
            '         {"name": "步骤 1", "command": "命令", "description": "说明", "connectionId": "可选服务器 ID"}\n'
            '       ]\n'
            '     }\n'
            '   - Verification：如何验证计划成功。\n'
            '5. 执行交接：用户批准后，必须按顺序执行持久化后的步骤，并使用 client_task_update 把状态更新为 running、success、failed 或 skipped。旧提示里可能仍出现 in_progress，但规范写法是 running。';
    return '$base$normalizedPlanInstructions';
  }

  String get compressionPrompt {
    return language == AppLanguage.en
        ? 'Summarize this conversation for continuing an SSH/SFTP assistant chat. Preserve server names, paths, commands, decisions, approvals, errors, and unresolved tasks. Be concise but operationally complete.'
        : '总结此对话以继续进行 SSH/SFTP 助手聊天。保留服务器名称、路径、命令、决策、审批、错误和未解决的任务。保持简明，但操作信息需完整。';
  }

  String get conversationMemorySummaryHeader {
    return language == AppLanguage.en
        ? 'Conversation memory summary:\n'
        : '对话历史记忆摘要：\n';
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
    final trimmedBase = baseUrl
        .trim()
        .split(RegExp(r'[?#]'))
        .first
        .replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.tryParse(trimmedBase);
    if (uri == null) return '$trimmedBase$normalizedPath';

    final basePath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (basePath.endsWith(normalizedPath)) return trimmedBase;
    const chatPath = '/chat/completions';
    const modelsPath = '/models';
    if (normalizedPath == modelsPath && basePath.endsWith(chatPath)) {
      final nextPath =
          '${basePath.substring(0, basePath.length - chatPath.length)}$modelsPath';
      return uri
          .replace(path: nextPath, query: null, fragment: null)
          .toString();
    }
    if (normalizedPath == chatPath && basePath.endsWith(modelsPath)) {
      final nextPath =
          '${basePath.substring(0, basePath.length - modelsPath.length)}$chatPath';
      return uri
          .replace(path: nextPath, query: null, fragment: null)
          .toString();
    }
    return '$trimmedBase$normalizedPath';
  }

  static bool looksLikeToolUnsupportedError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('tool_choice') ||
        lower.contains('"tools"') ||
        lower.contains("'tools'") ||
        lower.contains('tools is not supported') ||
        lower.contains('tool calls') ||
        lower.contains('function calling');
  }
}
