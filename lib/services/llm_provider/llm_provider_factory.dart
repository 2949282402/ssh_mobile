import '../storage_service.dart';
import 'llm_api_format.dart';
import 'llm_provider_adapter.dart';
import 'openai_chat_provider.dart';
import 'gemini_openai_compatible_provider.dart';
import 'anthropic_messages_provider.dart';

class LlmProviderFactory {
  static LlmProviderAdapter fromSettings(AiConnectionSettings settings) {
    switch (settings.apiFormat) {
      case LlmApiFormat.openAiChatCompletions:
        return const OpenAiChatProvider();
      case LlmApiFormat.geminiOpenAiCompatible:
        return const GeminiOpenAiCompatibleProvider();
      case LlmApiFormat.anthropicMessages:
        return const AnthropicMessagesProvider();
      case LlmApiFormat.openAiResponses:
        // TODO: Replace this fallback when OpenAI Responses provider is implemented.
        return const OpenAiChatProvider();
      case LlmApiFormat.geminiNative:
        // TODO: Replace this fallback when Gemini Native provider is implemented.
        return const OpenAiChatProvider();
    }
  }
}
