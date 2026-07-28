part of '../storage_service.dart';

extension TerminalOps on StorageService {
  Future<List<RestorableTmuxSession>> loadRestorableTmuxSessions() async {
    if (!_initialized || _prefs == null) return [];
    final cached = _restorableTmuxSessionsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(
      StorageService._restorableTmuxSessionsKey,
    );
    if (jsonStr == null || jsonStr.isEmpty) {
      return _restorableTmuxSessionsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final sessions = list
          .map(
            (item) =>
                RestorableTmuxSession.fromJson(item as Map<String, dynamic>),
          )
          .where((item) => getConnection(item.connectionId) != null)
          .toList();
      return _restorableTmuxSessionsCache = List.unmodifiable(sessions);
    } catch (e) {
      AppLogService.instance.error(
        'Failed to load restorable tmux sessions',
        error: e,
      );
      return _restorableTmuxSessionsCache = const [];
    }
  }

  Future<void> saveRestorableTmuxSession(RestorableTmuxSession session) async {
    if (!_initialized || _prefs == null) return;
    final sessions = [...await loadRestorableTmuxSessions()];
    sessions.removeWhere((item) => item.sessionId == session.sessionId);
    sessions.add(session);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> removeRestorableTmuxSession(String sessionId) async {
    if (!_initialized || _prefs == null) return;
    final sessions = [...await loadRestorableTmuxSessions()];
    sessions.removeWhere((item) => item.sessionId == sessionId);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> removeRestorableTmuxSessionsForConnection(
    String connectionId,
  ) async {
    if (!_initialized || _prefs == null) return;
    final sessions = [...await loadRestorableTmuxSessions()];
    sessions.removeWhere((item) => item.connectionId == connectionId);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> clearRestorableTmuxSessions() async {
    if (!_initialized || _prefs == null) return;
    _restorableTmuxSessionsCache = const [];
    _cancelPendingProtectedPrefWrite(StorageService._restorableTmuxSessionsKey);
    await _prefs!.remove(StorageService._restorableTmuxSessionsKey);
  }

  Future<List<TerminalHistoryRecord>> _loadTerminalHistoryRecords() async {
    if (!_initialized || _prefs == null) return const [];
    _requireDriftStorage(_driftTerminalHistoryActive, 'terminal history');
    final cached = _terminalHistoryRecordsCache;
    if (cached != null) return cached;
    return _loadDriftTerminalHistoryRecords();
  }

  Future<void> _saveTerminalHistoryRecord(TerminalHistoryRecord record) async {
    if (!_initialized || _prefs == null) return;
    _requireDriftStorage(_driftTerminalHistoryActive, 'terminal history');
    await _saveDriftTerminalHistoryRecord(record);
    notifyStorageListeners();
  }

  Future<void> _removeTerminalHistoryRecord(String sessionId) async {
    if (!_initialized || _prefs == null) return;
    _requireDriftStorage(_driftTerminalHistoryActive, 'terminal history');
    await _removeDriftTerminalHistoryRecord(sessionId);
    notifyStorageListeners();
  }

  Future<void> _saveRestorableTmuxSessions(
    List<RestorableTmuxSession> sessions, {
    bool immediate = false,
  }) async {
    _restorableTmuxSessionsCache = List.unmodifiable(sessions);
    final jsonStr = jsonEncode(sessions.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      StorageService._restorableTmuxSessionsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<void> _saveTerminalHistoryRecords(
    List<TerminalHistoryRecord> records, {
    bool immediate = false,
  }) async {
    final sorted = [...records]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _terminalHistoryRecordsCache = List.unmodifiable(sorted);
    _requireDriftStorage(_driftTerminalHistoryActive, 'terminal history');
    await _replaceDriftTerminalHistoryRecords(sorted);
  }
}
