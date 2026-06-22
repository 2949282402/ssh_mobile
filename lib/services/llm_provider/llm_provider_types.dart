import '../llm_chat_service.dart';

class LlmProviderToolCall {
  final String id;
  final String name;
  final String argumentsJson;

  const LlmProviderToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });
}

class LlmProviderRequest {
  final String baseUrl;
  final String apiKey;
  final String model;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> tools;
  final String openAiReasoningEffort;
  final bool deepSeekThinkingEnabled;
  final String deepSeekReasoningEffort;
  final bool includeTools;
  final bool includeUsage;
  final LlmCancellationToken? cancellationToken;
  final void Function(String textDelta)? onTextDelta;
  final int timeoutSeconds;

  const LlmProviderRequest({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.messages,
    this.tools = const [],
    this.openAiReasoningEffort = '',
    this.deepSeekThinkingEnabled = false,
    this.deepSeekReasoningEffort = '',
    this.includeTools = true,
    this.includeUsage = true,
    this.cancellationToken,
    this.onTextDelta,
    this.timeoutSeconds = 30,
  });
}

class LlmProviderResult {
  final String text;
  final String? reasoningContent;
  final List<LlmProviderToolCall> toolCalls;
  final LlmTokenUsage? usage;

  const LlmProviderResult({
    required this.text,
    this.reasoningContent,
    required this.toolCalls,
    this.usage,
  });
}
