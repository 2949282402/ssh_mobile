part of '../../services/storage_service.dart';

extension DriftSftpHistoryRepositoryOps on StorageService {
  Future<void> _recordSftpVisitedPath(String connectionId, String path) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) return;
    final normalizedPath = _normalizeSftpPath(path);
    if (connectionId.trim().isEmpty || normalizedPath.isEmpty) return;
    await database.sftpHistoryDao.recordVisitedPath(
      id: _traceUuid.v4(),
      connectionId: connectionId,
      path: normalizedPath,
      visitedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<List<SftpRecentPathRecord>> _loadSftpRecentPaths(
    String connectionId, {
    int limit = 30,
  }) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) return const [];
    final rows = await database.sftpHistoryDao.loadRecentPaths(
      connectionId,
      limit.clamp(1, 30),
    );
    return rows.map(_sftpRecentPathFromDrift).toList(growable: false);
  }

  Future<SftpFavoritePathRecord> _addSftpFavoritePath(
    String connectionId,
    String path,
    String name,
  ) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) {
      throw StateError('SFTP path history storage is unavailable.');
    }
    final normalizedPath = _normalizeSftpPath(path);
    final now = DateTime.now();
    final existing = await _findSftpFavoritePath(connectionId, normalizedPath);
    final record = existing == null
        ? SftpFavoritePathRecord(
            id: _traceUuid.v4(),
            connectionId: connectionId,
            path: normalizedPath,
            name: _normalizeSftpFavoriteName(name, normalizedPath),
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(
            name: _normalizeSftpFavoriteName(name, normalizedPath),
            updatedAt: now,
          );
    await database.sftpHistoryDao.upsertFavoritePath(
      _sftpFavoritePathToCompanion(record),
    );
    notifyStorageListeners();
    return record;
  }

  Future<void> _removeSftpFavoritePath(String id) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) return;
    await database.sftpHistoryDao.removeFavoritePath(id);
    notifyStorageListeners();
  }

  Future<void> _renameSftpFavoritePath(String id, String name) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) return;
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    await database.sftpHistoryDao.renameFavoritePath(
      id: id,
      name: normalized,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    notifyStorageListeners();
  }

  Future<List<SftpFavoritePathRecord>> _loadSftpFavoritePaths(
    String connectionId,
  ) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) return const [];
    final rows = await database.sftpHistoryDao.loadFavoritePaths(connectionId);
    return rows.map(_sftpFavoritePathFromDrift).toList(growable: false);
  }

  Future<SftpFavoritePathRecord?> _findSftpFavoritePath(
    String connectionId,
    String path,
  ) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) return null;
    final row = await database.sftpHistoryDao.findFavoritePath(
      connectionId: connectionId,
      path: _normalizeSftpPath(path),
    );
    return row == null ? null : _sftpFavoritePathFromDrift(row);
  }

  Future<void> _replaceDriftSftpPathHistory({
    required List<SftpRecentPathRecord> recentPaths,
    required List<SftpFavoritePathRecord> favoritePaths,
  }) async {
    final database = _database;
    if (!_driftSftpHistoryActive || database == null) return;
    await database.sftpHistoryDao.replaceAll(
      recentPaths: recentPaths
          .map(_sftpRecentPathToCompanion)
          .toList(growable: false),
      favoritePaths: favoritePaths
          .map(_sftpFavoritePathToCompanion)
          .toList(growable: false),
    );
  }

  SftpRecentPathRecord _sftpRecentPathFromDrift(db.SftpRecentPath row) {
    return SftpRecentPathRecord(
      id: row.id,
      connectionId: row.connectionId,
      path: row.path,
      visitedAt: _fromDbMillis(row.visitedAt),
    );
  }

  SftpFavoritePathRecord _sftpFavoritePathFromDrift(db.SftpFavoritePath row) {
    return SftpFavoritePathRecord(
      id: row.id,
      connectionId: row.connectionId,
      path: row.path,
      name: row.name,
      createdAt: _fromDbMillis(row.createdAt),
      updatedAt: _fromDbMillis(row.updatedAt),
    );
  }

  db.SftpRecentPathsCompanion _sftpRecentPathToCompanion(
    SftpRecentPathRecord record,
  ) {
    return db.SftpRecentPathsCompanion(
      id: drift.Value(record.id),
      connectionId: drift.Value(record.connectionId),
      path: drift.Value(_normalizeSftpPath(record.path)),
      visitedAt: drift.Value(_toDbMillis(record.visitedAt)),
    );
  }

  db.SftpFavoritePathsCompanion _sftpFavoritePathToCompanion(
    SftpFavoritePathRecord record,
  ) {
    return db.SftpFavoritePathsCompanion(
      id: drift.Value(record.id),
      connectionId: drift.Value(record.connectionId),
      path: drift.Value(_normalizeSftpPath(record.path)),
      name: drift.Value(_normalizeSftpFavoriteName(record.name, record.path)),
      createdAt: drift.Value(_toDbMillis(record.createdAt)),
      updatedAt: drift.Value(_toDbMillis(record.updatedAt)),
    );
  }

  String _normalizeSftpPath(String path) {
    final trimmed = path.trim();
    return trimmed.isEmpty ? '.' : trimmed;
  }

  String _normalizeSftpFavoriteName(String name, String path) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final normalizedPath = _normalizeSftpPath(path);
    if (normalizedPath == '/' || normalizedPath == '.') return normalizedPath;
    final slash = normalizedPath.lastIndexOf('/');
    if (slash == -1 || slash == normalizedPath.length - 1) {
      return normalizedPath;
    }
    return normalizedPath.substring(slash + 1);
  }
}
