part of '../storage_service.dart';

extension AiSkillOps on StorageService {
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
