import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/llm_runtime/llm_runtime_types.dart';

void main() {
  group('LlmTokenUsage tests', () {
    test('parses normal token usage properties', () {
      final usage = LlmTokenUsage.fromJson({
        'prompt_tokens': 10,
        'completion_tokens': 20,
        'total_tokens': 30,
        'prompt_cache_hit_tokens': 5,
        'prompt_cache_miss_tokens': 5,
        'reasoning_tokens': 15,
      });

      expect(usage.promptTokens, equals(10));
      expect(usage.completionTokens, equals(20));
      expect(usage.totalTokens, equals(30));
      expect(usage.promptCacheHitTokens, equals(5));
      expect(usage.promptCacheMissTokens, equals(5));
      expect(usage.reasoningTokens, equals(15));
    });

    test('parses nested token details correctly', () {
      final usage = LlmTokenUsage.fromJson({
        'prompt_tokens': 100,
        'completion_tokens': 200,
        'total_tokens': 300,
        'prompt_tokens_details': {'cached_tokens': 40},
        'prompt_cache_miss_tokens': 60,
        'completion_tokens_details': {'reasoning_tokens': 80},
      });

      expect(usage.promptTokens, equals(100));
      expect(usage.completionTokens, equals(200));
      expect(usage.totalTokens, equals(300));
      expect(usage.promptCacheHitTokens, equals(40));
      expect(usage.promptCacheMissTokens, equals(60));
      expect(usage.reasoningTokens, equals(80));
    });

    test('accepts numeric string values and parses them', () {
      final usage = LlmTokenUsage.fromJson({
        'prompt_tokens': '10',
        'completion_tokens': '20',
        'total_tokens': '30',
        'prompt_tokens_details': {'cached_tokens': '4'},
        'prompt_cache_miss_tokens': '6',
        'completion_tokens_details': {'reasoning_tokens': '8'},
      });

      expect(usage.promptTokens, equals(10));
      expect(usage.completionTokens, equals(20));
      expect(usage.totalTokens, equals(30));
      expect(usage.promptCacheHitTokens, equals(4));
      expect(usage.promptCacheMissTokens, equals(6));
      expect(usage.reasoningTokens, equals(8));
    });
  });
}
