import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_tool_service.dart';
import 'app_log_service.dart';
import 'app_settings.dart';
import 'multi_agent_coordinator.dart';
import 'storage_service.dart';
import 'tool_secret_policy.dart';

part 'llm_chat/llm_chat_types.dart';
part 'llm_chat/llm_system_prompt.dart';
part 'llm_chat/llm_context_compressor.dart';
part 'llm_chat/llm_chat_utils.dart';
part 'llm_chat/llm_safety_auditor.dart';
part 'llm_chat/llm_stream_handler.dart';

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
  });

  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    Set<String>? allowedTools,
    bool forceContextCompression = false,
  });
}

/// OpenAI 兼容 LLM 流式对话服务。
class LlmChatService implements LlmClientAdapter {
  static const int _networkRetryCount = 3;

  final StorageService storageService;
  final AiToolExecutor toolService;
  final MultiAgentCoordinatorAdapter multiAgentCoordinator;
  final AppLanguage language;
  final bool useCustomPrompts;
  final String customSystemPrompt;
  final String customPlannerPrompt;
  final String customOperatorPrompt;
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
    this.customReviewerPrompt = '',
    this.customSummarizerPrompt = '',
    this.customCoordinatorPrompt = '',
    MultiAgentCoordinatorAdapter? multiAgentCoordinator,
  }) : multiAgentCoordinator =
            multiAgentCoordinator ?? const MultiAgentCoordinator();

  String get systemPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn ? systemPromptEnPersona : systemPromptZhPersona;
    final baseSafety = isEn ? systemPromptEnSafety : systemPromptZhSafety;

    final persona = (useCustomPrompts && customSystemPrompt.trim().isNotEmpty)
        ? customSystemPrompt.trim()
        : basePersona.trim();

    return '$persona\n\n$baseSafety';
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
    final basePersona = isEn ? multiAgentPlannerPromptEnPersona : multiAgentPlannerPromptZhPersona;
    final baseSafety = isEn ? multiAgentPlannerPromptEnSafety : multiAgentPlannerPromptZhSafety;

    final persona = (useCustomPrompts && customPlannerPrompt.trim().isNotEmpty)
        ? customPlannerPrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get operatorPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn ? multiAgentOperatorPromptEnPersona : multiAgentOperatorPromptZhPersona;
    final baseSafety = isEn ? multiAgentOperatorPromptEnSafety : multiAgentOperatorPromptZhSafety;

    final persona = (useCustomPrompts && customOperatorPrompt.trim().isNotEmpty)
        ? customOperatorPrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get reviewerPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn ? multiAgentReviewerPromptEnPersona : multiAgentReviewerPromptZhPersona;
    final baseSafety = isEn ? multiAgentReviewerPromptEnSafety : multiAgentReviewerPromptZhSafety;

    final persona = (useCustomPrompts && customReviewerPrompt.trim().isNotEmpty)
        ? customReviewerPrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get summarizerPrompt {
    final isEn = language == AppLanguage.en;
    final basePersona = isEn ? multiAgentSummarizerPromptEnPersona : multiAgentSummarizerPromptZhPersona;
    final baseSafety = isEn ? multiAgentSummarizerPromptEnSafety : multiAgentSummarizerPromptZhSafety;

    final persona = (useCustomPrompts && customSummarizerPrompt.trim().isNotEmpty)
        ? customSummarizerPrompt.trim()
        : basePersona.trim();

    return '$persona $baseSafety';
  }

  String get coordinatorPrompt {
    return language == AppLanguage.en ? multiAgentCoordinatorPromptEn : multiAgentCoordinatorPromptZh;
  }

  @override
  Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
  }) async {
    final resolvedApiKey = apiKey?.trim().isNotEmpty == true
        ? apiKey!.trim()
        : await storageService.getAiApiKey();
    if (resolvedApiKey == null || resolvedApiKey.isEmpty) {
      throw StateError('API key is not configured.');
    }
    _assertValidHeaderApiKey(resolvedApiKey);

    final endpoint = Uri.parse(_joinUrl(baseUrl, '/models'));
    final timeoutSeconds = await storageService.getAiRequestTimeoutSeconds();
    final client = HttpClient();
    final startedAt = DateTime.now();
    AppLogService.instance.info(
      'LLM models request sent',
      details: 'endpoint=$endpoint',
    );
    try {
      final request = await client.getUrl(endpoint).timeout(
            Duration(seconds: timeoutSeconds),
          );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $resolvedApiKey',
      );
      final response = await request.close().timeout(
            Duration(seconds: timeoutSeconds),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        AppLogService.instance.warning(
          'LLM models request failed',
          details:
              'status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} bodyChars=${body.length}',
        );
        throw StateError(
          'Fetch models failed (${response.statusCode}): $body',
        );
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final data = decoded['data'];
      final models = <String>[];
      if (data is List) {
        for (final item in data) {
          if (item is Map && item['id'] is String) {
            models.add((item['id'] as String).trim());
          } else if (item is String) {
            models.add(item.trim());
          }
        }
      }
      models.removeWhere((item) => item.isEmpty);
      models.sort();
      AppLogService.instance.info(
        'LLM models received',
        details:
            'count=${models.length} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds}',
      );
      return models;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM models request error',
        error: e,
        stackTrace: stackTrace,
        details: 'endpoint=$endpoint timeoutSeconds=$timeoutSeconds',
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
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
  }) {
    return _sendImpl(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
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
    Set<String>? allowedTools,
    bool forceContextCompression = false,
  }) {
    return _streamImpl(
      messages: messages,
      modelOverride: modelOverride,
      requestToolApproval: requestToolApproval,
      onStats: onStats,
      onTrace: onTrace,
      cancellationToken: cancellationToken,
      allowedTools: allowedTools,
      forceContextCompression: forceContextCompression,
    );
  }

  static int estimateMessagesTokens(List<Map<String, dynamic>> messages) {
    return _estimateMessagesTokens(messages);
  }

  static int estimateTextTokens(String text) {
    return _estimateTextTokens(text);
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
