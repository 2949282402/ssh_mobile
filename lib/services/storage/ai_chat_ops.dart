part of '../storage_service.dart';

extension AiChatOps on StorageService {
  Future<List<AiChatRecord>> _loadAiChats() async {
    if (!_initialized || _prefs == null) return [];
    final cached = _aiChatsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(StorageService._aiChatsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _aiChatsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final chats = list
          .map((item) => AiChatRecord.fromJson(item as Map<String, dynamic>))
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
    final chats = upsertAiChatRecordsByUpdatedAt(
      await loadAiChats(),
      chat,
      limit: 80,
    );
    await _saveAiChats(chats, alreadySorted: true);
    notifyStorageListeners();
  }

  Future<void> _deleteAiChat(String id) async {
    if (!_initialized || _prefs == null) return;
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
    final jsonStr = jsonEncode(ordered.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      StorageService._aiChatsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<List<AiSkillRecord>> _loadAiSkills() async {
    if (!_initialized || _prefs == null) return [];
    final cached = _aiSkillsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(StorageService._aiSkillsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _aiSkillsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final skills = list
          .map((item) => AiSkillRecord.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return _aiSkillsCache = List.unmodifiable(skills);
    } catch (e) {
      AppLogService.instance.error('Failed to load AI skills', error: e);
      return _aiSkillsCache = const [];
    }
  }

  Future<void> _saveAiSkill(AiSkillRecord skill) async {
    if (!_initialized || _prefs == null) return;
    final skills = upsertAiSkillRecordsByUpdatedAt(
      await loadAiSkills(),
      skill,
    );
    await _saveAiSkills(skills, alreadySorted: true);
    notifyStorageListeners();
  }

  Future<void> _deleteAiSkill(String id) async {
    if (!_initialized || _prefs == null) return;
    final skills = (await loadAiSkills())
        .where((item) => item.id != id)
        .toList(growable: false);
    await _saveAiSkills(skills, alreadySorted: true);
    notifyStorageListeners();
  }

  Future<void> _saveAiSkills(
    List<AiSkillRecord> skills, {
    bool immediate = false,
    bool alreadySorted = false,
  }) async {
    final ordered = alreadySorted
        ? List<AiSkillRecord>.from(skills, growable: false)
        : ([...skills]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _aiSkillsCache = List.unmodifiable(ordered);
    final jsonStr = jsonEncode(ordered.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      StorageService._aiSkillsKey,
      jsonStr,
      immediate: immediate,
    );
  }
}
