import 'package:feature_ai/src/domain/ai_compat.dart';
import 'llm_api_format.dart';
import 'llm_provider_adapter.dart';
import 'openai_chat_provider.dart';
import 'gemini_openai_compatible_provider.dart';
import 'anthropic_messages_provider.dart';
import 'openai_responses_provider.dart';

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
        return const OpenAiResponsesProvider();
      case LlmApiFormat.geminiNative:
        // TODO: Replace this fallback when Gemini Native provider is implemented.
        return const OpenAiChatProvider();
    }
  }
}
