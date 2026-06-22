part of '../llm_chat_service.dart';

extension LlmChatServiceUtils on LlmChatService {
  Map<String, dynamic> _decodeArguments(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    return {};
  }

  String _joinUrl(String baseUrl, String path) {
    return LlmChatService.resolveOpenAiCompatibleUrl(baseUrl, path);
  }

  bool _looksLikeToolUnsupportedError(String body) {
    return LlmChatService.looksLikeToolUnsupportedError(body);
  }

  Set<String>? _normalizeToolNames(Set<String>? tools) {
    if (tools == null) return null;
    final normalized = <String>{};
    for (final tool in tools) {
      final name = tool.trim().toLowerCase();
      if (name.isNotEmpty) normalized.add(name);
    }
    return normalized;
  }

  String _latestUserGoal(List<Map<String, dynamic>> messages) {
    for (final message in messages.reversed) {
      if (message['role'] != 'user') {
        continue;
      }
      final content = '${message['content'] ?? ''}'.trim();
      if (content.isNotEmpty) {
        return _toolSecretPolicy.previewText(content, maxChars: 1200);
      }
    }
    return 'No explicit user goal provided.';
  }

  Map<String, dynamic> _mapFromValue(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return {
        for (final entry in value.entries) '${entry.key}': entry.value,
      };
    }
    return const {};
  }

  String _classifyToolResultOutcome(String result) {
    final trimmed = result.trim();
    if (trimmed.isEmpty) {
      return 'empty_result';
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is String && error.trim().isNotEmpty) {
          return 'tool_error';
        }
      }
      return _isMeaningfulToolResultValue(decoded) ? 'success' : 'empty_result';
    } catch (_) {
      return 'success';
    }
  }

  bool _looksLikeEmptyToolResult(String result) {
    final trimmed = result.trim();
    if (trimmed.isEmpty) {
      return true;
    }
    try {
      return !_isMeaningfulToolResultValue(jsonDecode(trimmed));
    } catch (_) {
      return false;
    }
  }

  bool _isMeaningfulToolResultValue(Object? value) {
    if (value == null) {
      return false;
    }
    if (value is String) {
      return value.trim().isNotEmpty;
    }
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is List) {
      return value.isNotEmpty && value.any(_isMeaningfulToolResultValue);
    }
    if (value is Map) {
      const ignoredKeys = {
        'execution',
        'limit',
        'returned',
        'truncated',
        'tool',
        'toolName',
        'connectionId',
        'connectionName',
        'serverPlatform',
        'command',
      };
      for (final entry in value.entries) {
        if (ignoredKeys.contains('${entry.key}')) {
          continue;
        }
        if (_isMeaningfulToolResultValue(entry.value)) {
          return true;
        }
      }
      return false;
    }
    return true;
  }

  void _emitReasoningTrace(
    void Function(LlmTraceEvent event)? onTrace,
    String reasoningContent,
  ) {
    final content = reasoningContent.trim();
    if (content.isEmpty) return;
    onTrace?.call(
      LlmTraceEvent(
        kind: 'reasoning',
        title: 'Deep thinking',
        content: content,
      ),
    );
  }

  void _emitBudgetTrace(
    void Function(LlmTraceEvent event)? onTrace, {
    required String title,
    required String content,
  }) {
    onTrace?.call(
      LlmTraceEvent(
        kind: 'budget',
        title: title,
        content: content,
      ),
    );
  }

  void _emitToolResultTrace(
    void Function(LlmTraceEvent event)? onTrace,
    String toolName,
    String result, {
    String outcome = 'success',
    bool cacheHit = false,
    bool dedupBlocked = false,
  }) {
    final resultPreview = _toolSecretPolicy.previewText(
      _prettyJsonString(result),
      maxChars: 1600,
    );
    onTrace?.call(
      LlmTraceEvent(
        kind: 'tool_result',
        title: 'Tool result: $toolName',
        content: _prettyJson({
          'tool': toolName,
          'outcome': outcome,
          'cacheHit': cacheHit,
          'dedupBlocked': dedupBlocked,
          'resultPreview': resultPreview,
        }),
      ),
    );
  }

  void _emitPostToolReviewTrace(
    void Function(LlmTraceEvent event)? onTrace,
    MultiAgentTrigger trigger,
    String contextText,
  ) {
    onTrace?.call(
      LlmTraceEvent(
        kind: 'multi_agent_post_tool_review',
        title: 'Post-tool multi-agent review triggered (${trigger.name})',
        content: contextText,
      ),
    );
  }

  String _prettyJsonString(String text) {
    try {
      return _prettyJson(_toolSecretPolicy.redactValue(jsonDecode(text)));
    } catch (_) {
      return _toolSecretPolicy.redactText(text);
    }
  }

  String _prettyJson(Object? value) {
    return const JsonEncoder.withIndent('  ')
        .convert(_toolSecretPolicy.redactValue(value));
  }

  String _toolContinuationSeparator(String visibleText) {
    if (visibleText.trim().isEmpty) return '';
    if (visibleText.endsWith('\n\n')) return '';
    if (visibleText.endsWith('\n')) return '\n';
    return '\n\n';
  }

  Map<String, dynamic> _providerReasoningParams({
    required String baseUrl,
    required String model,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
  }) {
    if (isDeepSeekModelId(model) || _isDeepSeekBaseUrl(baseUrl)) {
      final params = <String, dynamic>{
        'thinking': {
          'type': deepSeekThinkingEnabled ? 'enabled' : 'disabled',
        },
      };
      if (deepSeekThinkingEnabled) {
        params['reasoning_effort'] = DeepSeekReasoningEffort.normalize(
          deepSeekReasoningEffort,
        );
      }
      return params;
    }
    if (supportsOpenAiReasoningEffort(model)) {
      return {
        'reasoning_effort': OpenAiReasoningEffort.normalize(
          openAiReasoningEffort,
        ),
      };
    }
    return const {};
  }

  bool _looksLikeReasoningParamUnsupportedError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('reasoning_effort') ||
        lower.contains('xhigh') ||
        lower.contains('"thinking"') ||
        lower.contains("'thinking'") ||
        lower.contains('unknown parameter') ||
        lower.contains('unsupported parameter') ||
        lower.contains('does not support reasoning');
  }

  bool _isRetryableNetworkError(Object error) {
    return error is SocketException ||
        error is HttpException ||
        error is HandshakeException ||
        error is TlsException ||
        error is IOException;
  }

  Future<void> _delayBeforeNetworkRetry(
    int attempt,
    LlmCancellationToken? cancellationToken,
  ) async {
    cancellationToken?.throwIfCancelled();
    await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
    cancellationToken?.throwIfCancelled();
  }

  bool _isDeepSeekBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase().endsWith('deepseek.com') == true;
  }

  void _assertValidHeaderApiKey(String apiKey) {
    if (apiKey.contains(RegExp(r'[\r\n\t]')) ||
        apiKey.contains('package:flutter/') ||
        apiKey.contains('Failed assertion') ||
        apiKey.contains('docs.flutter.dev/testing/errors')) {
      throw const FormatException(
        'Invalid API key. Please re-enter the provider API key in LLM settings.',
      );
    }
  }

  AgentModelProfile _modelProfileForSettings(
    AiConnectionSettings settings, {
    String? mainModelOverride,
  }) {
    return AgentModelProfile(
      mainModel: mainModelOverride?.trim().isNotEmpty == true
          ? mainModelOverride!.trim()
          : settings.model,
      helperModel: settings.helperModel,
      auditModel: settings.auditModel,
      fallbackPolicy: settings.modelFallbackPolicy,
    );
  }

  int _nextRepeatedSignatureStreak(
    List<LlmToolLedgerEntry> ledger,
    String nextSignature,
  ) {
    var streak = 1;
    for (final entry in ledger.reversed) {
      if (entry.signature != nextSignature) {
        break;
      }
      streak += 1;
    }
    return streak;
  }

  bool _wouldTriggerAlternatingLoop(
    List<LlmToolLedgerEntry> ledger,
    String nextSignature,
  ) {
    if (ledger.length < 3) return false;
    final a = ledger[ledger.length - 3].signature;
    final b = ledger[ledger.length - 2].signature;
    final c = ledger[ledger.length - 1].signature;
    return a == c && a != b && nextSignature == b;
  }
}
