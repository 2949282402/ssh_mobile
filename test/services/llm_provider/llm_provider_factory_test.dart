import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/llm_provider/llm_api_format.dart';
import 'package:ssh_mobile/services/llm_provider/llm_provider_factory.dart';
import 'package:ssh_mobile/services/llm_provider/openai_chat_provider.dart';
import 'package:ssh_mobile/services/llm_provider/gemini_openai_compatible_provider.dart';
import 'package:ssh_mobile/services/llm_provider/anthropic_messages_provider.dart';
import 'package:ssh_mobile/services/storage_service.dart';

AiConnectionSettings buildSettings(LlmApiFormat format) {
  return AiConnectionSettings(
    baseUrl: 'https://example.com',
    model: 'model',
    contextWindowTokens: 4096,
    timeoutSeconds: 30,
    deepSeekThinkingEnabled: false,
    deepSeekReasoningEffort: '',
    openAiReasoningEffort: '',
    webSearchEnabled: false,
    webSearchMaxResults: 5,
    webSearchEngine: '',
    quarkSearchEndpoint: '',
    hasQuarkApiKey: false,
    multiAgentEnabled: false,
    multiAgentMaxAgents: 5,
    postToolReviewEnabled: false,
    toolCallBudget: 10,
    maxImageSizeBytes: 1024 * 1024,
    maxFileSizeBytes: 1024 * 1024,
    hasApiKey: false,
    activeApiKeyId: '',
    activeApiKeyMasked: '',
    useCustomPrompts: false,
    customSystemPrompt: '',
    customPlannerPrompt: '',
    customOperatorPrompt: '',
    customExplorePrompt: '',
    customReviewerPrompt: '',
    customSummarizerPrompt: '',
    customCoordinatorPrompt: '',
    apiFormat: format,
  );
}

void main() {
  group('LlmProviderFactory tests', () {
    test('returns OpenAiChatProvider for openAiChatCompletions', () {
      final settings = buildSettings(LlmApiFormat.openAiChatCompletions);
      final provider = LlmProviderFactory.fromSettings(settings);
      expect(provider, isA<OpenAiChatProvider>());
    });

    test(
      'returns GeminiOpenAiCompatibleProvider for geminiOpenAiCompatible',
      () {
        final settings = buildSettings(LlmApiFormat.geminiOpenAiCompatible);
        final provider = LlmProviderFactory.fromSettings(settings);
        expect(provider, isA<GeminiOpenAiCompatibleProvider>());
      },
    );

    test('returns AnthropicMessagesProvider for anthropicMessages', () {
      final settings = buildSettings(LlmApiFormat.anthropicMessages);
      final provider = LlmProviderFactory.fromSettings(settings);
      expect(provider, isA<AnthropicMessagesProvider>());
    });

    test(
      'falls back to OpenAiChatProvider for unimplemented openAiResponses',
      () {
        final settings = buildSettings(LlmApiFormat.openAiResponses);
        final provider = LlmProviderFactory.fromSettings(settings);
        expect(provider, isA<OpenAiChatProvider>());
      },
    );

    test('falls back to OpenAiChatProvider for unimplemented geminiNative', () {
      final settings = buildSettings(LlmApiFormat.geminiNative);
      final provider = LlmProviderFactory.fromSettings(settings);
      expect(provider, isA<OpenAiChatProvider>());
    });
  });
}
