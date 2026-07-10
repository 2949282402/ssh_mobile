import 'dart:convert';
import '../../../services/storage_service.dart';
import 'ai_chat_context_builder.dart';

class AiChatMessageMapper {
  final AiChatContextBuilder contextBuilder;

  const AiChatMessageMapper({required this.contextBuilder});

  List<Map<String, dynamic>> messagesForRequest(
    List<AiChatMessageRecord> messages, {
    AiChatMessageRecord? placeholder,
  }) {
    return messages
        .where((message) => message.role != 'error')
        .where((message) => message != placeholder)
        .map((message) {
          final textContent = contextContentFor(message);
          if (textContent.trim().isEmpty && message.attachments.isEmpty) {
            return null;
          }
          final role = message.role == 'user' ? 'user' : 'assistant';
          if (message.role == 'user' && message.attachments.isNotEmpty) {
            return <String, dynamic>{
              'role': role,
              'content': buildMultipartContent(
                textContent,
                message.attachments,
              ),
            };
          }
          return <String, dynamic>{'role': role, 'content': textContent};
        })
        .nonNulls
        .toList();
  }

  String contextContentFor(AiChatMessageRecord message) {
    if (message.role == 'user' && message.contextText != null) {
      return message.contextText!;
    }
    if (message.role == 'assistant') {
      return message.contextText ??
          contextBuilder.buildAssistantContextText(
            message.text,
            traces: message.traces,
          );
    }
    return message.text;
  }

  static List<Map<String, dynamic>> buildMultipartContent(
    String textContent,
    List<AiChatAttachment> attachments,
  ) {
    final textWithFiles = StringBuffer(textContent);
    for (final attachment in attachments) {
      if (!attachment.isImage) {
        if (attachment.isTextFile && attachment.dataBase64.isNotEmpty) {
          try {
            final decoded = utf8.decode(base64Decode(attachment.dataBase64));
            textWithFiles.write('\n\n[File: ${attachment.fileName}]\n$decoded');
          } catch (_) {
            textWithFiles.write(
              '\n\n[Attached file: ${attachment.fileName} (${_formatAttachmentSize(attachment.sizeBytes)})]',
            );
          }
        } else {
          textWithFiles.write(
            '\n\n[Attached file: ${attachment.fileName} (${_formatAttachmentSize(attachment.sizeBytes)})]',
          );
        }
      }
    }
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': textWithFiles.toString()},
    ];
    for (final attachment in attachments) {
      if (attachment.isImage && attachment.dataBase64.isNotEmpty) {
        parts.add({
          'type': 'image_url',
          'image_url': {
            'url':
                'data:${attachment.mimeType};base64,${attachment.dataBase64}',
          },
        });
      }
    }
    return parts;
  }

  static String _formatAttachmentSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}
