import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/screens/llm_chat_screen.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  test('fetched models replace default fallback models', () {
    final resolved = resolveFetchedModelOptions(
      fetchedModels: const ['gpt-4o', 'gpt-4.1', 'gpt-4o'],
      fallbackModels: const ['deepseek-v4-flash', 'deepseek-v4-pro'],
    );

    expect(resolved, const ['gpt-4.1', 'gpt-4o']);
    expect(resolved, isNot(contains('deepseek-v4-flash')));
    expect(resolved, isNot(contains('deepseek-v4-pro')));
  });

  test('empty fetched models keep the existing fallback list', () {
    final resolved = resolveFetchedModelOptions(
      fetchedModels: const [],
      fallbackModels: const ['deepseek-v4-flash', 'custom-model'],
    );

    expect(resolved, const ['custom-model', 'deepseek-v4-flash']);
  });

  test('initial model options prefer cached models for the current base URL',
      () {
    final resolved = buildInitialModelOptions(
      currentModel: 'gpt-4.1',
      cachedModels: const ['gpt-4o', 'gpt-4.1-mini'],
    );

    expect(resolved, const ['gpt-4.1', 'gpt-4.1-mini', 'gpt-4o']);
    expect(resolved, isNot(contains('deepseek-v4-flash')));
  });

  test('initial model options fall back to defaults when cache is empty', () {
    final resolved = buildInitialModelOptions(
      currentModel: 'custom-model',
      cachedModels: const [],
    );

    expect(
      resolved,
      const ['custom-model', 'deepseek-v4-flash', 'deepseek-v4-pro'],
    );
  });

  test('DeepSeek settings are shown only for DeepSeek-like model ids', () {
    expect(isDeepSeekModelId('deepseek-v4-flash'), isTrue);
    expect(isDeepSeekModelId('DeepSeek-R1'), isTrue);
    expect(isDeepSeekModelId('gpt-5'), isFalse);
  });

  test('OpenAI reasoning effort is limited to reasoning-capable model ids', () {
    expect(supportsOpenAiReasoningEffort('gpt-5'), isTrue);
    expect(supportsOpenAiReasoningEffort('o3-mini'), isTrue);
    expect(supportsOpenAiReasoningEffort('gpt-4.1'), isFalse);
  });

  test('API key masking keeps the first four and last two characters', () {
    expect(maskAiApiKey('sk-abcdefghijklmnopqrstuvwxyz'),
        'sk-a***********************yz');
    expect(maskAiApiKey('abc123'), 'abc123');
  });
}
