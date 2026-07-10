part of '../storage_service.dart';

const int _aiChatRetentionLimit = 80;

extension AiChatOps on StorageService {
  Future<List<AiChatRecord>> _loadAiChats() async {
    if (!_initialized || _prefs == null) return [];
    if (_driftAiChatsActive) {
      final cached = _aiChatsCache;
      if (cached != null) return cached;
      return _loadDriftAiChats();
    }
    final cached = _aiChatsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(StorageService._aiChatsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _aiChatsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final chats =
          list
              .map(
                (item) => AiChatRecord.fromJson(item as Map<String, dynamic>),
              )
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return _aiChatsCache = List.unmodifiable(chats);
    } catch (e) {
      AppLogService.instance.error('Failed to load AI chats', error: e);
      return _aiChatsCache = const [];
    }
  }

  Future<void> _saveAiChat(AiChatRecord chat) async {
    if (!_initialized || _prefs == null) return;
    if (_driftAiChatsActive) {
      await _saveDriftAiChat(chat);
      notifyStorageListeners();
      return;
    }
    final chats = upsertAiChatRecordsByUpdatedAt(
      await loadAiChats(),
      chat,
      limit: _aiChatRetentionLimit,
    );
    await _saveAiChats(chats, alreadySorted: true);
    notifyStorageListeners();
  }

  Future<void> _deleteAiChat(String id) async {
    if (!_initialized || _prefs == null) return;
    if (_driftAiChatsActive) {
      await _deleteDriftAiChat(id);
      notifyStorageListeners();
      return;
    }
    final chats = (await loadAiChats())
        .where((item) => item.id != id)
        .toList(growable: false);
    await _saveAiChats(chats, alreadySorted: true);
    notifyStorageListeners();
  }

  Future<void> _saveAiChats(
    List<AiChatRecord> chats, {
    bool immediate = false,
    bool alreadySorted = false,
  }) async {
    final ordered = alreadySorted
        ? List<AiChatRecord>.from(chats, growable: false)
        : ([...chats]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _aiChatsCache = List.unmodifiable(ordered);
    if (_driftAiChatsActive) {
      await _replaceDriftAiChats(ordered);
      return;
    }
    final jsonStr = jsonEncode(ordered.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      StorageService._aiChatsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<List<AgentRunMetrics>> _loadAgentRunMetrics() async {
    if (!_initialized || _prefs == null) return const [];
    if (_driftAgentMetricsActive) {
      final cached = _agentRunMetricsCache;
      if (cached != null) return cached;
      return _loadDriftAgentRunMetrics();
    }
    final cached = _agentRunMetricsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(
      StorageService._agentRunMetricsKey,
    );
    if (jsonStr == null || jsonStr.isEmpty) {
      return _agentRunMetricsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final metrics =
          list
              .map(
                (item) =>
                    AgentRunMetrics.fromJson(item as Map<String, dynamic>),
              )
              .toList()
            ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
      return _agentRunMetricsCache = List.unmodifiable(metrics);
    } catch (e) {
      AppLogService.instance.error(
        'Failed to load agent run metrics',
        error: e,
      );
      return _agentRunMetricsCache = const [];
    }
  }

  Future<void> _saveAgentRunMetrics(AgentRunMetrics metrics) async {
    if (!_initialized || _prefs == null) return;
    if (_driftAgentMetricsActive) {
      await _saveDriftAgentRunMetrics(metrics);
      return;
    }
    final current = await loadAgentRunMetrics();
    final next = <AgentRunMetrics>[
      metrics,
      ...current.where((item) => item.id != metrics.id),
    ];
    if (next.length > 200) {
      next.removeRange(200, next.length);
    }
    _agentRunMetricsCache = List.unmodifiable(next);
    await _writeProtectedPrefBuffered(
      StorageService._agentRunMetricsKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
      immediate: false,
    );
  }
}
