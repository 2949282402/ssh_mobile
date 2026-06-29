import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/llm_provider/gemini_openai_compatible_provider.dart';
import 'package:ssh_mobile/services/llm_provider/openai_chat_provider.dart';

void main() {
  group('GeminiOpenAiCompatibleProvider tests', () {
    test('inherits from OpenAiChatProvider', () {
      const provider = GeminiOpenAiCompatibleProvider();
      expect(provider, isA<OpenAiChatProvider>());
    });
  });
}
