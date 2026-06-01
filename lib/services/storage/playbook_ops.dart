part of '../storage_service.dart';

extension PlaybookOps on StorageService {
  Future<List<Playbook>> _loadPlaybooks() async {
    if (!_initialized || _prefs == null) return [];
    final cached = _playbooksCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(StorageService._playbooksKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _playbooksCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final playbooks = list
          .map((item) => Playbook.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return _playbooksCache = List.unmodifiable(playbooks);
    } catch (e) {
      AppLogService.instance.error('Failed to load playbooks', error: e);
      return _playbooksCache = const [];
    }
  }

  Future<void> _savePlaybook(Playbook playbook) async {
    if (!_initialized || _prefs == null) return;
    final playbooks = upsertPlaybooksByUpdatedAt(
      await loadPlaybooks(),
      playbook,
    );
    await _savePlaybooks(playbooks, alreadySorted: true);
    notifyStorageListeners();
  }

  Future<void> _deletePlaybook(String id) async {
    if (!_initialized || _prefs == null) return;
    final playbooks = (await loadPlaybooks())
        .where((item) => item.id != id)
        .toList(growable: false);
    await _savePlaybooks(playbooks, alreadySorted: true);
    notifyStorageListeners();
  }

  Future<void> _savePlaybooks(
    List<Playbook> playbooks, {
    bool immediate = false,
    bool alreadySorted = false,
  }) async {
    final ordered = alreadySorted
        ? List<Playbook>.from(playbooks, growable: false)
        : ([...playbooks]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _playbooksCache = List.unmodifiable(ordered);
    final jsonStr = jsonEncode(ordered.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      StorageService._playbooksKey,
      jsonStr,
      immediate: immediate,
    );
  }
}
