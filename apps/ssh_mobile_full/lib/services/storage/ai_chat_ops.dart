part of '../storage_service.dart';

const int _aiChatRetentionLimit = 80;

extension AiChatOps on StorageService {
  Future<List<AiChatRecord>> _loadAiChats() async {
    if (!_initialized || _prefs == null) return const [];
    _requireDriftStorage(_driftAiChatsActive, 'AI chat');
    final cached = _aiChatsCache;
    if (cached != null) return cached;
    return _loadDriftAiChats();
  }

  Future<void> _saveAiChat(AiChatRecord chat) async {
    if (!_initialized || _prefs == null) return;
    _requireDriftStorage(_driftAiChatsActive, 'AI chat');
    await _saveDriftAiChat(chat);
    notifyStorageListeners();
  }

  Future<void> _deleteAiChat(String id) async {
    if (!_initialized || _prefs == null) return;
    _requireDriftStorage(_driftAiChatsActive, 'AI chat');
    await _deleteDriftAiChat(id);
    notifyStorageListeners();
  }

  Future<void> _saveAiChats(
    List<AiChatRecord> chats, {
    bool immediate = false,
    bool alreadySorted = false,
  }) async {
    _requireDriftStorage(_driftAiChatsActive, 'AI chat');
    final ordered = alreadySorted
        ? List<AiChatRecord>.from(chats, growable: false)
        : ([...chats]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _aiChatsCache = List.unmodifiable(ordered);
    await _replaceDriftAiChats(ordered);
  }

  Future<List<AgentRunMetrics>> _loadAgentRunMetrics() async {
    if (!_initialized || _prefs == null) return const [];
    _requireDriftStorage(_driftAgentMetricsActive, 'agent metrics');
    final cached = _agentRunMetricsCache;
    if (cached != null) return cached;
    return _loadDriftAgentRunMetrics();
  }

  Future<void> _saveAgentRunMetrics(AgentRunMetrics metrics) async {
    if (!_initialized || _prefs == null) return;
    _requireDriftStorage(_driftAgentMetricsActive, 'agent metrics');
    await _saveDriftAgentRunMetrics(metrics);
  }
}
