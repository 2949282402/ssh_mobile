import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
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

  test(
    'initial model options prefer cached models for the current base URL',
    () {
      final resolved = buildInitialModelOptions(
        currentModel: 'gpt-4.1',
        cachedModels: const ['gpt-4o', 'gpt-4.1-mini'],
      );

      expect(resolved, const ['gpt-4.1', 'gpt-4.1-mini', 'gpt-4o']);
      expect(resolved, isNot(contains('deepseek-v4-flash')));
    },
  );

  test('initial model options fall back to defaults when cache is empty', () {
    final resolved = buildInitialModelOptions(
      currentModel: 'custom-model',
      cachedModels: const [],
    );

    expect(resolved, const [
      'custom-model',
      'deepseek-v4-flash',
      'deepseek-v4-pro',
    ]);
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
    expect(
      maskAiApiKey('sk-abcdefghijklmnopqrstuvwxyz'),
      'sk-a***********************yz',
    );
    expect(maskAiApiKey('abc123'), 'abc123');
  });

  test(
    'LlmChatScreen.buildMultipartContent handles pure text with no attachments',
    () {
      final result = LlmChatScreen.buildMultipartContent('hello world', []);
      expect(result.length, 1);
      expect(result[0]['type'], 'text');
      expect(result[0]['text'], 'hello world');
    },
  );

  test(
    'LlmChatScreen.buildMultipartContent generates vision image_url format for images',
    () {
      final imageAttachment = AiChatAttachment(
        fileName: 'photo.png',
        mimeType: 'image/png',
        sizeBytes: 256,
        dataBase64:
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );

      final result = LlmChatScreen.buildMultipartContent('check this image', [
        imageAttachment,
      ]);
      expect(result.length, 2);
      expect(result[0]['type'], 'text');
      expect(result[0]['text'], 'check this image');

      expect(result[1]['type'], 'image_url');
      final imageUrlMap = result[1]['image_url'] as Map<String, dynamic>;
      expect(
        imageUrlMap['url'],
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
    },
  );

  test(
    'LlmChatScreen.buildMultipartContent injects decodable text file content inlined',
    () {
      final textAttachment = AiChatAttachment(
        fileName: 'notes.txt',
        mimeType: 'text/plain',
        sizeBytes: 15,
        dataBase64: 'SGVsbG8gdGV4dCBmaWxl',
      );

      final result = LlmChatScreen.buildMultipartContent('some question', [
        textAttachment,
      ]);
      expect(result.length, 1);
      expect(result[0]['type'], 'text');
      expect(result[0]['text'], contains('some question'));
      expect(result[0]['text'], contains('[File: notes.txt]'));
      expect(result[0]['text'], contains('Hello text file'));
    },
  );

  test(
    'LlmChatScreen.buildMultipartContent appends binary file placeholders',
    () {
      final binAttachment = AiChatAttachment(
        fileName: 'archive.zip',
        mimeType: 'application/zip',
        sizeBytes: 1024 * 1024 * 3,
        dataBase64: 'UEsDBAoAAAAAA...',
      );

      final result = LlmChatScreen.buildMultipartContent('sending archive', [
        binAttachment,
      ]);
      expect(result.length, 1);
      expect(result[0]['type'], 'text');
      expect(result[0]['text'], contains('sending archive'));
      expect(
        result[0]['text'],
        contains('[Attached file: archive.zip (3.0 MB)]'),
      );
    },
  );

  test(
    'approved plan execution context uses persisted todo steps as source of truth',
    () {
      final planMessage = AiChatMessageRecord(
        role: 'assistant',
        text: 'Plan',
        createdAt: DateTime.utc(2026, 1, 1, 12, 0),
        todoSteps: const [
          AiTodoStep(
            id: 'task-1',
            name: 'Inspect service',
            command: 'systemctl status nginx',
            description: 'Check nginx status',
            connectionId: 'server-1',
          ),
        ],
      );

      final contextText = buildApprovedPlanExecutionContext(
        userText: 'Execute the approved plan.',
        planMessage: planMessage,
        language: AppLanguage.en,
      );

      expect(contextText, contains('Approved execution plan:'));
      expect(contextText, contains('task-1'));
      expect(contextText, contains('systemctl status nginx'));
      expect(contextText, contains('"connectionId":"server-1"'));
      expect(contextText, contains('status="running"'));
      expect(contextText, contains('Execute the approved plan.'));
    },
  );
}
