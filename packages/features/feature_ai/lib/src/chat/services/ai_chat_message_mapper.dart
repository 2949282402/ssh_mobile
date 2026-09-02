import 'dart:convert';
import 'package:feature_ai/src/domain/ai_compat.dart';
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
    final boundedText = _boundTextContent(textContent);
    final textWithFiles = StringBuffer(boundedText);
    var payloadBytes = utf8.encode(boundedText).length;
    final imageParts = <Map<String, dynamic>>[];
    var processedAttachments = 0;
    for (final attachment in attachments) {
      if (processedAttachments >= AiAttachmentBudget.maxAttachmentCount) {
        break;
      }
      processedAttachments++;
      if (attachment.isImage) {
        final dataBase64 = attachment.dataBase64;
        if (!_canInlineImage(attachment)) {
          payloadBytes = _appendAttachmentPlaceholder(
            textWithFiles,
            attachment,
            payloadBytes,
          );
          continue;
        }
        final dataUrl = 'data:${attachment.mimeType};base64,$dataBase64';
        final imageBytes = utf8.encode(dataUrl).length;
        if (payloadBytes + imageBytes >
            AiAttachmentBudget.maxRequestPayloadBytes) {
          payloadBytes = _appendAttachmentPlaceholder(
            textWithFiles,
            attachment,
            payloadBytes,
          );
          continue;
        }
        imageParts.add({
          'type': 'image_url',
          'image_url': {'url': dataUrl},
        });
        payloadBytes += imageBytes;
        continue;
      }

      if (attachment.isTextFile && _canInlineText(attachment)) {
        try {
          final decodedBytes = base64Decode(attachment.dataBase64);
          if (decodedBytes.length > AiAttachmentBudget.maxInlineTextBytes) {
            payloadBytes = _appendAttachmentPlaceholder(
              textWithFiles,
              attachment,
              payloadBytes,
            );
            continue;
          }
          final decoded = utf8.decode(decodedBytes);
          if (_estimatedTokenCount(decoded) >
              AiAttachmentBudget.maxDecodedTextTokens) {
            payloadBytes = _appendAttachmentPlaceholder(
              textWithFiles,
              attachment,
              payloadBytes,
            );
            continue;
          }
          final content = '\n\n[File: ${attachment.fileName}]\n$decoded';
          final contentBytes = utf8.encode(content).length;
          if (payloadBytes + contentBytes >
              AiAttachmentBudget.maxRequestPayloadBytes) {
            payloadBytes = _appendAttachmentPlaceholder(
              textWithFiles,
              attachment,
              payloadBytes,
            );
          } else {
            textWithFiles.write(content);
            payloadBytes += contentBytes;
          }
        } catch (_) {
          payloadBytes = _appendAttachmentPlaceholder(
            textWithFiles,
            attachment,
            payloadBytes,
          );
        }
      } else {
        payloadBytes = _appendAttachmentPlaceholder(
          textWithFiles,
          attachment,
          payloadBytes,
        );
      }
    }
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': textWithFiles.toString()},
    ];
    parts.addAll(imageParts);
    return parts;
  }

  static bool _canInlineText(AiChatAttachment attachment) {
    if (attachment.dataBase64.isEmpty) return false;
    if (attachment.sizeBytes <= 0 ||
        attachment.sizeBytes > AiAttachmentBudget.maxInlineTextBytes) {
      return false;
    }
    // Check the encoded length before base64Decode so a persisted oversized
    // attachment cannot allocate its complete decoded representation.
    final maxEncodedChars = _maxBase64CharsForBytes(
      AiAttachmentBudget.maxInlineTextBytes,
    );
    return attachment.dataBase64.length <= maxEncodedChars;
  }

  static bool _canInlineImage(AiChatAttachment attachment) {
    if (attachment.dataBase64.isEmpty) return false;
    if (attachment.sizeBytes <= 0 ||
        attachment.sizeBytes > AiAttachmentBudget.maxSingleAttachmentBytes) {
      return false;
    }
    final maxEncodedChars = _maxBase64CharsForBytes(
      AiAttachmentBudget.maxSingleAttachmentBytes,
    );
    return attachment.dataBase64.length <= maxEncodedChars &&
        attachment.dataBase64.length <=
            AiAttachmentBudget.maxRequestPayloadBytes;
  }

  static int _maxBase64CharsForBytes(int bytes) {
    if (bytes <= 0) return 0;
    return ((bytes + 2) ~/ 3) * 4;
  }

  static int _estimatedTokenCount(String text) {
    // A deliberately conservative estimate: a non-ASCII rune can represent a
    // complete token, so never allow more runes than the hard token budget.
    return text.runes.length;
  }

  static String _boundTextContent(String text) {
    final encodedLength = utf8.encode(text).length;
    if (encodedLength <= AiAttachmentBudget.maxRequestPayloadBytes) {
      return text;
    }
    const marker = '\n\n[Message text truncated to request budget]';
    final markerBytes = utf8.encode(marker).length;
    final prefixBudget =
        AiAttachmentBudget.maxRequestPayloadBytes - markerBytes;
    var end = text.length < prefixBudget ? text.length : prefixBudget;
    var prefix = text.substring(0, end);
    while (prefix.isNotEmpty && utf8.encode(prefix).length > prefixBudget) {
      end--;
      prefix = text.substring(0, end);
    }
    return '$prefix$marker';
  }

  static int _appendAttachmentPlaceholder(
    StringBuffer buffer,
    AiChatAttachment attachment,
    int payloadBytes,
  ) {
    final placeholder =
        '\n\n[Attached file: ${attachment.fileName} (${_formatAttachmentSize(attachment.sizeBytes)})]';
    final placeholderBytes = utf8.encode(placeholder).length;
    if (payloadBytes + placeholderBytes >
        AiAttachmentBudget.maxRequestPayloadBytes) {
      return payloadBytes;
    }
    buffer.write(placeholder);
    return payloadBytes + placeholderBytes;
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
