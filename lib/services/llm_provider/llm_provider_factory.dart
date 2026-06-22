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
        throw UnimplementedError('OpenAI Responses provider is not implemented yet.');
      case LlmApiFormat.geminiNative:
        throw UnimplementedError('Gemini Native provider is not implemented yet.');
    }
  }
}
