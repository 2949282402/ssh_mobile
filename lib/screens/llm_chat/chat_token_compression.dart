part of '../llm_chat_screen.dart';

extension _ChatTokenCompression on _LlmChatScreenState {
  Future<String?> _contextTextForUser(
    String text, {
    List<RagChunk> ragChunks = const [],
  }) async {
    final lines = <String>[];
    if (_selectedConnectionIds.isNotEmpty) {
      final storage = context.read<StorageService>();
      final serverInfos = <String>[];
      for (final id in _selectedConnectionIds) {
        final connection = storage.getConnection(id);
        if (connection != null) {
          serverInfos.add(
            '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
          );
        }
      }
      if (serverInfos.isNotEmpty) {
        lines.add(
          'Target servers:\n${serverInfos.join('\n')}',
        );
      }
    }

    if (ragChunks.isNotEmpty) {
      final isEn = context.read<AppSettings>().isEnglish;
      final ragLines = <String>[];
      ragLines.add(isEn
          ? '【Ops Knowledge Base Reference Information】:'
          : '【运维知识库参考信息】：');
      for (final chunk in ragChunks) {
        ragLines.add('---');
        ragLines.add(isEn
            ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
            : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})');
        ragLines.add('${isEn ? 'Content' : '内容'}:\n${chunk.text}');
      }
      ragLines.add('---');
      lines.add(ragLines.join('\n'));
    }

    if (lines.isEmpty) return null;
    return '${lines.join('\n\n')}\n\nUser request:\n$text';
  }

  String _contextTextForAssistant(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) {
    final trimmed = text.trim();
    final body = trimmed.isEmpty
        ? trimmed
        : !_shouldOmitAssistantBody(trimmed)
            ? trimmed
            : _slimAssistantBody(trimmed);
    if (traces.isEmpty) return body;

    final buffer = StringBuffer();
    if (body.isNotEmpty) {
      buffer.writeln(body);
      buffer.writeln();
    }
    buffer.writeln('Assistant execution memory:');
    for (final trace in traces) {
      buffer
        ..writeln('[${trace.kind}] ${trace.title}')
        ..writeln(_traceMemoryContent(trace))
        ..writeln();
    }
    return buffer.toString().trimRight();
  }

  String _traceMemoryContent(AiMessageTrace trace) {
    final trimmed = trace.content.trim();
    if (trimmed.length <= 2500) return trimmed;
    final preview =
        trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(900);
    return '[Large ${trace.kind} output omitted from future context. '
        'The full trace remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  String _slimAssistantBody(String trimmed) {
    final preview =
        trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(420);
    final type = _largeAssistantBodyType(trimmed);
    return '[Large $type output omitted from future context. '
        'The full content remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  bool _shouldOmitAssistantBody(String text) {
    final lowerText = text.toLowerCase();
    if (text.length > 6000) return true;
    if (text.length > 2500 && _codeFenceCount(text) >= 2) return true;
    if (text.length > 2500 &&
        (lowerText.contains('<html') || lowerText.contains('<!doctype'))) {
      return true;
    }
    if (text.length > 3000 && _markdownDocumentScore(text) >= 10) return true;
    return false;
  }

  String _largeAssistantBodyType(String text) {
    final lowerText = text.toLowerCase();
    if (lowerText.contains('<html') || lowerText.contains('<!doctype')) {
      return 'HTML';
    }
    if (_codeFenceCount(text) >= 2) return 'code/document';
    if (_markdownDocumentScore(text) >= 10) return 'Markdown/document';
    return 'document';
  }

  int _codeFenceCount(String text) {
    return RegExp(r'```').allMatches(text).length;
  }

  int _markdownDocumentScore(String text) {
    var score = 0;
    for (final line in text.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) score += 2;
      if (trimmed.startsWith('|')) score++;
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) score++;
      if (RegExp(r'^\d+\. ').hasMatch(trimmed)) score++;
    }
    return score;
  }

  int _contextTokensFor(AiChatRecord chat) {
    final key = _contextTokenKey(chat);
    if (_contextTokenCacheKey == key) return _cachedContextTokens;
    final now = DateTime.now();
    if (_sending &&
        _contextTokenCacheChatId == chat.id &&
        _contextTokenCacheKey != null &&
        now.difference(_lastContextTokenEstimateAt) <
            const Duration(milliseconds: 1500)) {
      return _cachedContextTokens;
    }
    _contextTokenCacheKey = key;
    _contextTokenCacheChatId = chat.id;
    _lastContextTokenEstimateAt = now;
    _cachedContextTokens = _estimatedContextTokens(chat.messages);
    return _cachedContextTokens;
  }

  String _contextTokenKey(AiChatRecord chat) {
    final messages = chat.messages;
    if (messages.isEmpty) return '${chat.id}:0';
    final last = messages.last;
    return [
      chat.id,
      messages.length,
      last.role,
      last.createdAt.microsecondsSinceEpoch,
      last.text.length,
      last.contextText?.length ?? 0,
      last.traces.length,
    ].join(':');
  }

  int _estimatedContextTokens(List<AiChatMessageRecord> messages) {
    final mapped = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': 'system'},
      ..._messagesForRequest(messages),
    ];
    return LlmChatService.estimateMessagesTokens(mapped);
  }

  String _contextUsage(int used, int limit, double ratio) {
    final percent = (ratio * 100).clamp(0, 999).toStringAsFixed(1);
    return '${_compactTokens(used)} / ${AiContextWindowSize.label(limit)} ($percent%)';
  }

  String _compactTokens(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(2)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }

  ValueListenable<String>? _streamingTextFor(
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
    return _streamingAssistantText;
  }

  ValueListenable<String>? _streamingStatusFor(
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
    return _streamingAssistantStatus;
  }
}
