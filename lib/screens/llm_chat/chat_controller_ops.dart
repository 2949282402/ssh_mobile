part of '../llm_chat_screen.dart';

extension _ChatControllerOps on _LlmChatScreenState {
  void _replaceChat(AiChatRecord chat, {bool sort = true}) {
    _chats = sort
        ? upsertAiChatRecordsByUpdatedAt(_chats, chat)
        : _replaceChatWithoutReordering(_chats, chat);
    if (chat.messages.isNotEmpty) {
      _savedHistoryChats = sort && _historyLoadStarted
          ? upsertAiChatRecordsByUpdatedAt(_savedHistoryChats, chat)
          : _replaceChatWithoutReordering(
              _savedHistoryChats,
              chat,
              insertIfMissing: false,
            );
    }
    _activeChatId = chat.id;
  }

  List<AiChatRecord> _replaceChatWithoutReordering(
    List<AiChatRecord> chats,
    AiChatRecord chat, {
    bool insertIfMissing = true,
  }) {
    final next = [...chats];
    final index = next.indexWhere((item) => item.id == chat.id);
    if (index >= 0) {
      next[index] = chat;
    } else if (insertIfMissing) {
      next.insert(0, chat);
    }
    return next;
  }

  AiChatRecord? _chatById(String id) {
    for (final chat in _chats) {
      if (chat.id == id) return chat;
    }
    for (final chat in _savedHistoryChats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  AiChatRecord _newChatRecord(String model) {
    final now = DateTime.now();
    return AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: _AiStrings(context.read<AppSettings>().language).newChat,
      model: model,
      messages: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  String _titleFrom(String text, _AiStrings strings) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return strings.newChat;
    return cleaned.length > 22 ? '${cleaned.substring(0, 22)}...' : cleaned;
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  List<Map<String, dynamic>> _messagesForRequest(
    List<AiChatMessageRecord> messages, {
    AiChatMessageRecord? placeholder,
  }) {
    return messages
        .where((message) => message.role != 'error')
        .where((message) => message != placeholder)
        .map((message) {
          final textContent = _contextContentFor(message);
          if (textContent.trim().isEmpty && message.attachments.isEmpty) {
            return null;
          }
          final role = message.role == 'user' ? 'user' : 'assistant';
          if (message.role == 'user' && message.attachments.isNotEmpty) {
            return <String, dynamic>{
              'role': role,
              'content':
                  buildMultipartContent(textContent, message.attachments),
            };
          }
          return <String, dynamic>{
            'role': role,
            'content': textContent,
          };
        })
        .nonNulls
        .toList();
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

  String _contextContentFor(AiChatMessageRecord message) {
    if (message.role == 'user' && message.contextText != null) {
      return message.contextText!;
    }
    if (message.role == 'assistant') {
      return message.contextText ??
          _contextTextForAssistant(message.text, traces: message.traces);
    }
    return message.text;
  }
}
