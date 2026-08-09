/// App Shell 兼容后端使用的 SFTP 路径记录模型。
///
/// 正式 SFTP 页面使用 feature_sftp 自己的 `sftp.db`；这些模型只服务于
/// 尚未删除的旧后端调用面，避免旧后端重新依赖统一数据库。
final class SftpRecentPathRecord {
  /// 创建最近访问路径记录。
  const SftpRecentPathRecord({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.visitedAt,
  });

  final String id;
  final String connectionId;
  final String path;
  final DateTime visitedAt;
}

/// App Shell 兼容后端使用的 SFTP 收藏路径模型。
final class SftpFavoritePathRecord {
  /// 创建收藏路径记录。
  const SftpFavoritePathRecord({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String connectionId;
  final String path;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 返回更新展示名称后的新记录。
  SftpFavoritePathRecord copyWith({String? name, DateTime? updatedAt}) =>
      SftpFavoritePathRecord(
        id: id,
        connectionId: connectionId,
        path: path,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 旧 SFTP 后端所需的路径历史能力；不拥有数据库。
abstract interface class SftpPathHistoryStore {
  /// 记录一次目录访问。
  Future<void> recordVisitedPath(String connectionId, String path);

  /// 读取最近目录。
  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  });

  /// 创建或更新收藏目录。
  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  );

  /// 删除收藏目录。
  Future<void> removeFavoritePath(String id);

  /// 更新收藏目录名称。
  Future<void> renameFavoritePath(String id, String name);

  /// 读取收藏目录。
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId);

  /// 按连接和路径查找收藏目录。
  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  );
}

/// 兼容后端的进程内路径记录实现。
///
/// 该实现不参与正式 Feature 数据迁移，只在旧 App Service 仍被调用时
/// 保持当前进程内行为；持久化归属已经转移到 feature_sftp。
final class InMemorySftpPathHistoryStore implements SftpPathHistoryStore {
  static const int _maxRecentPathsPerConnection = 30;

  final Map<String, List<SftpRecentPathRecord>> _recentByConnection = {};
  final Map<String, SftpFavoritePathRecord> _favoritesById = {};
  int _nextId = 0;

  @override
  Future<void> recordVisitedPath(String connectionId, String path) async {
    final normalizedConnectionId = connectionId.trim();
    final normalizedPath = _normalizePath(path);
    if (normalizedConnectionId.isEmpty) return;
    final records = _recentByConnection.putIfAbsent(
      normalizedConnectionId,
      () => [],
    );
    records.removeWhere((record) => record.path == normalizedPath);
    records.insert(
      0,
      SftpRecentPathRecord(
        id: _newId(),
        connectionId: normalizedConnectionId,
        path: normalizedPath,
        visitedAt: DateTime.now(),
      ),
    );
    if (records.length > _maxRecentPathsPerConnection) {
      records.removeRange(_maxRecentPathsPerConnection, records.length);
    }
  }

  @override
  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) async {
    final records = _recentByConnection[connectionId.trim()] ?? const [];
    return List.unmodifiable(records.take(limit.clamp(1, 30)));
  }

  @override
  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) async {
    final normalizedConnectionId = connectionId.trim();
    final normalizedPath = _normalizePath(path);
    final now = DateTime.now();
    final existing = await findFavoritePath(
      normalizedConnectionId,
      normalizedPath,
    );
    final record = existing == null
        ? SftpFavoritePathRecord(
            id: _newId(),
            connectionId: normalizedConnectionId,
            path: normalizedPath,
            name: _normalizeName(name, normalizedPath),
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(
            name: _normalizeName(name, normalizedPath),
            updatedAt: now,
          );
    _favoritesById[record.id] = record;
    return record;
  }

  @override
  Future<void> removeFavoritePath(String id) async {
    _favoritesById.remove(id);
  }

  @override
  Future<void> renameFavoritePath(String id, String name) async {
    final record = _favoritesById[id];
    final normalizedName = name.trim();
    if (record == null || normalizedName.isEmpty) return;
    _favoritesById[id] = record.copyWith(
      name: normalizedName,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(
    String connectionId,
  ) async {
    final records =
        _favoritesById.values
            .where((record) => record.connectionId == connectionId.trim())
            .toList()
          ..sort((a, b) {
            final byName = a.name.compareTo(b.name);
            return byName != 0 ? byName : a.path.compareTo(b.path);
          });
    return List.unmodifiable(records);
  }

  @override
  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) async {
    final normalizedPath = _normalizePath(path);
    for (final record in _favoritesById.values) {
      if (record.connectionId == connectionId.trim() &&
          record.path == normalizedPath) {
        return record;
      }
    }
    return null;
  }

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';

  static String _normalizePath(String path) {
    final normalized = path.trim();
    return normalized.isEmpty ? '.' : normalized;
  }

  static String _normalizeName(String name, String path) {
    final normalized = name.trim();
    if (normalized.isNotEmpty) return normalized;
    if (path == '/' || path == '.') return path;
    final slash = path.lastIndexOf('/');
    return slash < 0 || slash == path.length - 1
        ? path
        : path.substring(slash + 1);
  }
}
