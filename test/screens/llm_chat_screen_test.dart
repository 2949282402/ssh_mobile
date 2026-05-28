import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/screens/llm_chat_screen.dart';

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
}
