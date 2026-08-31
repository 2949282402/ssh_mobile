part of 'test_storage_adapter.dart';

/// Owns terminal history, SFTP path, playbook, and import/export facade operations.
mixin _TestStorageAdapterSession on _TestStorageAdapterBase {
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() async {
    return terminalMetadataStore.loadTerminalHistoryRecords();
  }

  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) =>
      terminalMetadataStore.saveTerminalHistoryRecord(record);

  Future<void> removeTerminalHistoryRecord(String sessionId) =>
      terminalMetadataStore.removeTerminalHistoryRecord(sessionId);

  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) => sftpPathHistory.loadRecentPaths(connectionId, limit: limit);

  Future<void> recordVisitedPath(String connectionId, String path) =>
      sftpPathHistory.recordVisitedPath(connectionId, path);

  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) => sftpPathHistory.addFavoritePath(connectionId, path, name);

  Future<void> removeFavoritePath(String id) =>
      sftpPathHistory.removeFavoritePath(id);

  Future<void> renameFavoritePath(String id, String name) =>
      sftpPathHistory.renameFavoritePath(id, name);

  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId) =>
      sftpPathHistory.loadFavoritePaths(connectionId);

  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) => sftpPathHistory.findFavoritePath(connectionId, path);

  @override
  Future<List<playbook.Playbook>> loadPlaybooks() =>
      playbookRepository.loadPlaybooks();

  @override
  Future<void> savePlaybook(playbook.Playbook item) =>
      playbookRepository.savePlaybook(item);

  @override
  Future<void> deletePlaybook(String id) =>
      playbookRepository.deletePlaybook(id);

  @override
  Future<int?> savePlaybookIfRevisionMatches({
    required String playbookId,
    required int expectedRevision,
    required playbook.Playbook playbook,
  }) => playbookRepository.savePlaybookIfRevisionMatches(
    playbookId: playbookId,
    expectedRevision: expectedRevision,
    playbook: playbook,
  );

  @override
  Future<void> saveRunSnapshot(playbook.PlaybookRunSnapshot snapshot) =>
      playbookRepository.saveRunSnapshot(snapshot);

  Future<String> exportAppDataJson() => _delegate.exportAppDataJson();
  Future<void> importAppDataJson(String jsonText) =>
      _delegate.importAppDataJson(jsonText);

  void attachAiRepositoryLoader(Future<ai.AiRepository> Function() loader) {
    _delegate.attachAiRepositoryLoader(loader);
  }

  void registerOnImportCallback(FutureOr<void> Function() callback) =>
      _delegate.registerOnImportCallback(callback);
}
