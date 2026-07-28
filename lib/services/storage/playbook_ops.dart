part of '../storage_service.dart';

extension PlaybookOps on StorageService {
  Future<List<Playbook>> _loadPlaybooks() async {
    if (!_initialized || _prefs == null) return const [];
    _requireDriftStorage(_driftPlaybooksActive, 'playbook');
    final cached = _playbooksCache;
    if (cached != null) return cached;
    return _loadDriftPlaybooks();
  }

  Future<void> _savePlaybook(Playbook playbook) async {
    if (!_initialized || _prefs == null) return;
    _requireDriftStorage(_driftPlaybooksActive, 'playbook');
    await _saveDriftPlaybook(playbook);
    notifyStorageListeners();
  }

  Future<void> _deletePlaybook(String id) async {
    if (!_initialized || _prefs == null) return;
    _requireDriftStorage(_driftPlaybooksActive, 'playbook');
    await _deleteDriftPlaybook(id);
    notifyStorageListeners();
  }

  Future<void> _savePlaybooks(
    List<Playbook> playbooks, {
    bool immediate = false,
    bool alreadySorted = false,
  }) async {
    _requireDriftStorage(_driftPlaybooksActive, 'playbook');
    final ordered = alreadySorted
        ? List<Playbook>.from(playbooks, growable: false)
        : ([...playbooks]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _playbooksCache = List.unmodifiable(ordered);
    await _replaceDriftPlaybooks(ordered);
  }
}
