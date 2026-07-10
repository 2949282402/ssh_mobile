import 'llm_provider_types.dart';

abstract interface class LlmProviderAdapter {
  Future<List<String>> fetchModels({required String baseUrl, String? apiKey});

  Future<LlmProviderResult> complete(LlmProviderRequest request);

  Future<LlmProviderResult> streamChat(LlmProviderRequest request);

  Map<String, dynamic> buildAssistantToolCallMessage({
    required String? text,
    required List<LlmProviderToolCall> toolCalls,
    String? reasoningContent,
  });

  Map<String, dynamic> buildToolResultMessage({
    required LlmProviderToolCall call,
    required String result,
  });
}
