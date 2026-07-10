import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_context_builder.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/utils/text_chunker.dart';

void main() {
  group('AiChatContextBuilder Tests', () {
    const builder = AiChatContextBuilder();

    test('buildApprovedPlanExecutionContext supports Chinese and English', () {
      final steps = [
        const AiTodoStep(
          id: 'step-1',
          name: 'Task 1',
          command: 'echo 1',
          description: 'Desc 1',
          connectionId: 'conn-1',
        ),
      ];
      final planMessage = AiChatMessageRecord(
        role: 'assistant',
        text: 'plan text',
        todoSteps: steps,
        createdAt: DateTime.now(),
      );

      final enResult = builder.buildApprovedPlanExecutionContext(
        userText: 'Trigger en',
        planMessage: planMessage,
        language: AppLanguage.en,
      );

      expect(enResult, contains('Approved execution plan:'));
      expect(enResult, contains('step-1'));
      expect(enResult, contains('Trigger en'));

      final zhResult = builder.buildApprovedPlanExecutionContext(
        userText: 'Trigger zh',
        planMessage: planMessage,
        language: AppLanguage.zh,
      );

      expect(zhResult, contains('已批准执行计划：'));
      expect(zhResult, contains('step-1'));
      expect(zhResult, contains('Trigger zh'));
    });

    test('buildUserContextText formats target servers and RAG chunks', () {
      final connections = [
        const AiChatSelectedConnectionContext(
          id: '1',
          name: 'Server A',
          username: 'root',
          host: '127.0.0.1',
          port: 22,
        ),
      ];

      final chunks = [
        const RagChunk(
          id: 'chunk-1',
          documentId: 'doc-1',
          documentName: 'doc.txt',
          text: 'retrieved text content',
          charStartIndex: 0,
          charEndIndex: 22,
          metadata: {'chunkIndex': 2},
        ),
      ];

      final result = builder.buildUserContextText(
        text: 'hello',
        language: AppLanguage.en,
        isEnglish: true,
        selectedConnections: connections,
        ragChunks: chunks,
      );

      expect(result, contains('Target servers:'));
      expect(result, contains('- Server A (id: 1, host: root@127.0.0.1:22)'));
      expect(result, contains('【Ops Knowledge Base Reference Information】:'));
      expect(result, contains('Source: [doc.txt] (Chunk #2)'));
      expect(result, contains('retrieved text content'));
      expect(result, contains('User request:\nhello'));
    });

    test('buildUserContextText skips target servers when empty', () {
      final result = builder.buildUserContextText(
        text: 'hello',
        language: AppLanguage.en,
        isEnglish: true,
        selectedConnections: const [],
      );

      expect(result, isNot(contains('Target servers:')));
      expect(result, equals('User request:\nhello'));
    });

    test('buildAssistantContextText with no traces returns body directly', () {
      final result = builder.buildAssistantContextText('short body');
      expect(result, equals('short body'));
    });

    test('buildAssistantContextText appends traces and formats memory', () {
      final traces = [
        AiMessageTrace(
          id: 'trace-1',
          kind: 'tool_result',
          title: 'Run command',
          content: 'success response',
          createdAt: DateTime.now(),
        ),
      ];

      final result = builder.buildAssistantContextText(
        'assistant reply',
        traces: traces,
      );

      expect(result, contains('assistant reply'));
      expect(result, contains('Assistant execution memory:'));
      expect(result, contains('[tool_result] Run command'));
      expect(result, contains('success response'));
    });

    test(
      'buildAssistantContextText redacts large trace content (>2500 chars)',
      () {
        final largeContent = 'a' * 3000;
        final traces = [
          AiMessageTrace(
            id: 'trace-1',
            kind: 'tool_result',
            title: 'Run command',
            content: largeContent,
            createdAt: DateTime.now(),
          ),
        ];

        final result = builder.buildAssistantContextText(
          'reply',
          traces: traces,
        );

        expect(
          result,
          contains('[Large tool_result output omitted from future context.'),
        );
        expect(result, contains('Length: 3000 chars.'));
      },
    );

    test('buildAssistantContextText body trimming rules', () {
      // Rule 1: length > 6000
      final veryLongText = 'a' * 6005;
      final result1 = builder.buildAssistantContextText(veryLongText);
      expect(
        result1,
        contains('Large document output omitted from future context.'),
      );

      // Rule 2: length > 2500 && code fences >= 2
      final codeFenceText = '```\n${'a' * 2500}\n```';
      final result2 = builder.buildAssistantContextText(codeFenceText);
      expect(
        result2,
        contains('Large code/document output omitted from future context.'),
      );

      // Rule 3: length > 2500 && HTML
      final htmlText = '<html>${'a' * 2500}</html>';
      final result3 = builder.buildAssistantContextText(htmlText);
      expect(
        result3,
        contains('Large HTML output omitted from future context.'),
      );

      // Rule 4: length > 3000 && Markdown document score >= 10
      final mdText =
          '# Header 1\n# Header 2\n# Header 3\n# Header 4\n# Header 5\n'
          '${'a' * 3000}';
      final result4 = builder.buildAssistantContextText(mdText);
      expect(
        result4,
        contains('Large Markdown/document output omitted from future context.'),
      );

      // Rule 5: ordinary text does not trim
      final ordinary = 'a' * 2000;
      final result5 = builder.buildAssistantContextText(ordinary);
      expect(result5, equals(ordinary));
    });
  });
}
