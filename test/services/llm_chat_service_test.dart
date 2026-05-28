import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';

void main() {
  group('LlmChatService token estimates', () {
    test('counts ASCII in four-character chunks and non-ASCII per rune', () {
      expect(LlmChatService.estimateTextTokens(''), 0);
      expect(LlmChatService.estimateTextTokens('abcd'), 1);
      expect(LlmChatService.estimateTextTokens('abcde'), 2);
      expect(LlmChatService.estimateTextTokens('中文'), 2);
      expect(LlmChatService.estimateTextTokens('abcd中文'), 3);
    });

    test('adds per-message overhead', () {
      final tokens = LlmChatService.estimateMessagesTokens([
        {'role': 'user', 'content': 'abcd'},
        {'role': 'assistant', 'content': '中文'},
      ]);

      expect(tokens, 4 + 1 + 1 + 4 + 3 + 2);
    });
  });

  group('OpenAI-compatible URL resolution', () {
    test('appends chat completion path to a versioned base URL', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/',
          '/chat/completions',
        ),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('switches between full chat and models endpoints', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/chat/completions',
          '/models',
        ),
        'https://api.example.com/v1/models',
      );
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/models',
          '/chat/completions',
        ),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('drops accidental query strings and fragments', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1?debug=1#frag',
          '/models',
        ),
        'https://api.example.com/v1/models',
      );
    });
  });

  test('recognizes provider errors for unsupported function tools', () {
    expect(
      LlmChatService.looksLikeToolUnsupportedError(
        '{"error":"tool_choice is not supported"}',
      ),
      isTrue,
    );
    expect(
      LlmChatService.looksLikeToolUnsupportedError('invalid model'),
      isFalse,
    );
  });
}
