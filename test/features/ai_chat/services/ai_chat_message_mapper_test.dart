import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_context_builder.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_message_mapper.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  group('AiChatMessageMapper Tests', () {
    const contextBuilder = AiChatContextBuilder();
    const mapper = AiChatMessageMapper(contextBuilder: contextBuilder);

    test('messagesForRequest maps standard user and assistant messages', () {
      final messages = [
        AiChatMessageRecord(
          role: 'user',
          text: 'hello',
          createdAt: DateTime.now(),
        ),
        AiChatMessageRecord(
          role: 'assistant',
          text: 'hi there',
          createdAt: DateTime.now(),
        ),
      ];

      final result = mapper.messagesForRequest(messages);

      expect(result, hasLength(2));
      expect(result[0]['role'], 'user');
      expect(result[0]['content'], 'hello');
      expect(result[1]['role'], 'assistant');
      expect(result[1]['content'], 'hi there');
    });

    test('messagesForRequest ignores error role and placeholder assistant', () {
      final placeholder = AiChatMessageRecord(
        role: 'assistant',
        text: 'should be ignored',
        createdAt: DateTime.now(),
      );

      final messages = [
        AiChatMessageRecord(
          role: 'user',
          text: 'hello',
          createdAt: DateTime.now(),
        ),
        AiChatMessageRecord(
          role: 'error',
          text: 'some error',
          createdAt: DateTime.now(),
        ),
        placeholder,
      ];

      final result =
          mapper.messagesForRequest(messages, placeholder: placeholder);

      expect(result, hasLength(1));
      expect(result[0]['role'], 'user');
      expect(result[0]['content'], 'hello');
    });

    test('messagesForRequest uses user contextText when present', () {
      final messages = [
        AiChatMessageRecord(
          role: 'user',
          text: 'raw text',
          contextText: 'custom context user text',
          createdAt: DateTime.now(),
        ),
      ];

      final result = mapper.messagesForRequest(messages);
      expect(result[0]['content'], 'custom context user text');
    });

    test(
        'messagesForRequest uses assistant contextText when present, or falls back to builder',
        () {
      final messages = [
        AiChatMessageRecord(
          role: 'assistant',
          text: 'raw text',
          contextText: 'custom context assistant text',
          createdAt: DateTime.now(),
        ),
        AiChatMessageRecord(
          role: 'assistant',
          text: 'fallback assistant text',
          traces: [
            AiMessageTrace(
              id: 't-1',
              kind: 'tool_result',
              title: 'trace',
              content: 'trace-content',
              createdAt: DateTime.now(),
            )
          ],
          createdAt: DateTime.now(),
        ),
      ];

      final result = mapper.messagesForRequest(messages);

      expect(result[0]['content'], 'custom context assistant text');
      expect(result[1]['content'], contains('fallback assistant text'));
      expect(result[1]['content'], contains('Assistant execution memory:'));
      expect(result[1]['content'], contains('trace-content'));
    });

    test(
        'messagesForRequest encodes text and image attachments for user message',
        () {
      final textData = base64Encode(utf8.encode('file text content'));
      final imageData = base64Encode([1, 2, 3]);

      final attachments = [
        AiChatAttachment(
          fileName: 'log.txt',
          mimeType: 'text/plain',
          sizeBytes: 100,
          dataBase64: textData,
        ),
        AiChatAttachment(
          fileName: 'error.txt',
          mimeType: 'text/plain',
          sizeBytes: 200,
          dataBase64: 'invalid_base64_^^^',
        ),
        AiChatAttachment(
          fileName: 'image.png',
          mimeType: 'image/png',
          sizeBytes: 300,
          dataBase64: imageData,
        ),
        const AiChatAttachment(
          fileName: 'binary.zip',
          mimeType: 'application/zip',
          sizeBytes: 400,
          dataBase64: 'xyz',
        ),
      ];

      final message = AiChatMessageRecord(
        role: 'user',
        text: 'check attachments',
        attachments: attachments,
        createdAt: DateTime.now(),
      );

      final result = mapper.messagesForRequest([message]);

      expect(result, hasLength(1));
      final content = result[0]['content'];
      expect(content, isA<List>());

      final parts = content as List;
      // Parts: 1 text part (containing textContent + text attachment text), 1 image part
      expect(parts, hasLength(2));
      expect(parts[0]['type'], 'text');
      expect(parts[0]['text'], contains('check attachments'));
      // Text file successfully decoded
      expect(parts[0]['text'], contains('[File: log.txt]'));
      expect(parts[0]['text'], contains('file text content'));
      // Text file decode failed fallback
      expect(parts[0]['text'], contains('[Attached file: error.txt (200 B)]'));
      // Binary file summary fallback
      expect(parts[0]['text'], contains('[Attached file: binary.zip (400 B)]'));

      // Image part
      expect(parts[1]['type'], 'image_url');
      expect(parts[1]['image_url']['url'], 'data:image/png;base64,$imageData');
    });

    test(
        'messagesForRequest filters out message with empty text and no attachments',
        () {
      final message = AiChatMessageRecord(
        role: 'user',
        text: '   ',
        createdAt: DateTime.now(),
      );

      final result = mapper.messagesForRequest([message]);
      expect(result, isEmpty);
    });
  });
}
