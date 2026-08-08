part of 'ai_chat_viewmodel.dart';

extension AiChatContextActions on AiChatViewModel {
  Future<String?> contextTextForUser(
    String text, {
    List<RagChunk> ragChunks = const [],
    AiChatMessageRecord? approvedPlanMessage,
  }) async {
    final selected = <AiChatSelectedConnectionContext>[];
    for (final id in _selectedConnectionIds) {
      final conn = _storageService.getConnection(id);
      if (conn != null) {
        selected.add(
          AiChatSelectedConnectionContext(
            id: conn.id,
            name: conn.name,
            username: conn.username,
            host: conn.host,
            port: conn.port,
          ),
        );
      }
    }
    return _contextBuilder.buildUserContextText(
      text: text,
      language: _appSettings.language,
      isEnglish: _appSettings.isEnglish,
      selectedConnections: selected,
      ragChunks: ragChunks,
      approvedPlanMessage: approvedPlanMessage,
    );
  }

  String _contextTextForAssistant(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) {
    return _contextBuilder.buildAssistantContextText(text, traces: traces);
  }

  int contextTokensFor(AiChatRecord chat) {
    return _tokenEstimator.contextTokensFor(chat, sending: _sending);
  }

  ValueListenable<String>? streamingTextFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return streamingAssistantText;
  }

  ValueListenable<String>? streamingStatusFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return streamingAssistantStatus;
  }

  // 私有辅助方法
  AiChatRecord? _chatById(String id) {
    for (final chat in _chats) {
      if (chat.id == id) return chat;
    }
    for (final chat in _savedHistoryChats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  void _replaceChat(
    AiChatRecord chat, {
    bool sort = true,
    bool activate = true,
  }) {
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
    if (activate) {
      _activeChatId = chat.id;
    }
  }

  List<AiChatRecord> _replaceChatWithoutReordering(
    List<AiChatRecord> chats,
    AiChatRecord chat, {
    bool insertIfMissing = true,
  }) {
    final index = chats.indexWhere((item) => item.id == chat.id);
    if (index >= 0) {
      return [...chats]..[index] = chat;
    }
    return insertIfMissing ? [chat, ...chats] : chats;
  }

  AiChatRecord _newChatRecord(String model) {
    final now = DateTime.now();
    final strings = AiStrings(_appSettings.language);
    return AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: strings.newChat,
      model: model,
      messages: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  String _titleFrom(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) {
      return AiStrings(_appSettings.language).newChat;
    }
    return cleaned.length > 22 ? '${cleaned.substring(0, 22)}...' : cleaned;
  }

  List<Map<String, dynamic>> _messagesForRequest(
    List<AiChatMessageRecord> messages, {
    AiChatMessageRecord? placeholder,
  }) {
    return _messageMapper.messagesForRequest(
      messages,
      placeholder: placeholder,
    );
  }

  static List<Map<String, dynamic>> buildMultipartContent(
    String textContent,
    List<AiChatAttachment> attachments,
  ) {
    return AiChatMessageMapper.buildMultipartContent(textContent, attachments);
  }
}
