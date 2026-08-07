// SFTP 路径历史 Repository 的 Drift 实现。
//
// Repository 只持有 Module 注入的数据库引用；所有数据库释放由
// SftpModule 执行，避免多个对象重复 close 同一个 Drift 句柄。

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/sftp_models.dart';
import '../../domain/sftp_ports.dart';
import '../database/sftp_database.dart';

/// 基于 sftp.db 的路径历史 Repository。
final class DriftSftpPathHistoryRepository
    implements SftpPathHistoryRepository {
  /// 创建 Repository。
  DriftSftpPathHistoryRepository(this.database);

  final SftpDatabase database;
  static const Uuid _uuid = Uuid();

  @override
  Future<void> recordVisitedPath(String connectionId, String path) async {
    final normalizedPath = _normalizePath(path);
    if (connectionId.trim().isEmpty || normalizedPath.isEmpty) return;
    await database.sftpPathHistoryDao.recordVisitedPath(
      id: _uuid.v4(),
      connectionId: connectionId,
      path: normalizedPath,
      visitedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) async {
    final rows = await database.sftpPathHistoryDao.loadRecentPaths(
      connectionId,
      limit.clamp(1, 30),
    );
    return rows.map(_fromRecentRow).toList(growable: false);
  }

  @override
  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) async {
    final normalizedPath = _normalizePath(path);
    final now = DateTime.now();
    final current = await findFavoritePath(connectionId, normalizedPath);
    final record = current == null
        ? SftpFavoritePathRecord(
            id: _uuid.v4(),
            connectionId: connectionId,
            path: normalizedPath,
            name: _normalizeName(name, normalizedPath),
            createdAt: now,
            updatedAt: now,
          )
        : current.copyWith(
            name: _normalizeName(name, normalizedPath),
            updatedAt: now,
          );
    await database.sftpPathHistoryDao.upsertFavoritePath(
      _toFavoriteCompanion(record),
    );
    return record;
  }

  @override
  Future<void> removeFavoritePath(String id) {
    return database.sftpPathHistoryDao.removeFavoritePath(id);
  }

  @override
  Future<void> renameFavoritePath(String id, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    await database.sftpPathHistoryDao.renameFavoritePath(
      id: id,
      name: normalized,
      updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(
    String connectionId,
  ) async {
    final rows = await database.sftpPathHistoryDao.loadFavoritePaths(
      connectionId,
    );
    return rows.map(_fromFavoriteRow).toList(growable: false);
  }

  @override
  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) async {
    final row = await database.sftpPathHistoryDao.findFavoritePath(
      connectionId: connectionId,
      path: _normalizePath(path),
    );
    return row == null ? null : _fromFavoriteRow(row);
  }

  SftpRecentPathRecord _fromRecentRow(SftpRecentPath row) =>
      SftpRecentPathRecord(
        id: row.id,
        connectionId: row.connectionId,
        path: row.path,
        visitedAt: DateTime.fromMillisecondsSinceEpoch(
          row.visitedAt,
          isUtc: true,
        ).toLocal(),
      );

  SftpFavoritePathRecord _fromFavoriteRow(SftpFavoritePath row) =>
      SftpFavoritePathRecord(
        id: row.id,
        connectionId: row.connectionId,
        path: row.path,
        name: row.name,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row.createdAt,
          isUtc: true,
        ).toLocal(),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          row.updatedAt,
          isUtc: true,
        ).toLocal(),
      );

  SftpFavoritePathsCompanion _toFavoriteCompanion(
    SftpFavoritePathRecord record,
  ) => SftpFavoritePathsCompanion(
    id: Value(record.id),
    connectionId: Value(record.connectionId),
    path: Value(_normalizePath(record.path)),
    name: Value(_normalizeName(record.name, record.path)),
    createdAt: Value(record.createdAt.toUtc().millisecondsSinceEpoch),
    updatedAt: Value(record.updatedAt.toUtc().millisecondsSinceEpoch),
  );

  String _normalizePath(String path) {
    final trimmed = path.trim();
    return trimmed.isEmpty ? '.' : trimmed;
  }

  String _normalizeName(String name, String path) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final normalizedPath = _normalizePath(path);
    if (normalizedPath == '/' || normalizedPath == '.') return normalizedPath;
    final slash = normalizedPath.lastIndexOf('/');
    if (slash == -1 || slash == normalizedPath.length - 1) {
      return normalizedPath;
    }
    return normalizedPath.substring(slash + 1);
  }
}
