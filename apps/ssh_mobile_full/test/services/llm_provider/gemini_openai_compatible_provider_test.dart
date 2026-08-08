import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_llm.dart';

void main() {
  group('GeminiOpenAiCompatibleProvider tests', () {
    test('inherits from OpenAiChatProvider', () {
      const provider = GeminiOpenAiCompatibleProvider();
      expect(provider, isA<OpenAiChatProvider>());
    });
  });
}
