import '../../../services/llm_chat_service.dart';
import '../../../services/storage_service.dart';
import 'ai_chat_message_mapper.dart';

class AiChatTokenEstimator {
  final AiChatMessageMapper _messageMapper;

  String? _contextTokenCacheKey;
  String? _contextTokenCacheChatId;
  int _cachedContextTokens = 0;
  DateTime _lastContextTokenEstimateAt = DateTime.fromMillisecondsSinceEpoch(0);

  AiChatTokenEstimator({
    required AiChatMessageMapper messageMapper,
  }) : _messageMapper = messageMapper;

  int contextTokensFor(
    AiChatRecord chat, {
    required bool sending,
  }) {
    final key = _contextTokenKey(chat);
    if (_contextTokenCacheKey == key) return _cachedContextTokens;
    final now = DateTime.now();
    if (sending &&
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

  void invalidate() {
    _contextTokenCacheKey = null;
    _contextTokenCacheChatId = null;
    _cachedContextTokens = 0;
    _lastContextTokenEstimateAt = DateTime.fromMillisecondsSinceEpoch(0);
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
      ..._messageMapper.messagesForRequest(messages),
    ];
    return LlmChatService.estimateMessagesTokens(mapped);
  }
}
