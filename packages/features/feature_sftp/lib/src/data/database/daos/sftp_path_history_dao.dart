part of '../sftp_database.dart';

/// SFTP 路径历史 DAO；有界策略在数据库边界执行，避免记录无限增长。
@DriftAccessor(tables: [SftpRecentPaths, SftpFavoritePaths])
class SftpPathHistoryDao extends DatabaseAccessor<SftpDatabase>
    with _$SftpPathHistoryDaoMixin {
  /// 创建 DAO。
  SftpPathHistoryDao(super.db);

  /// 记录访问路径并清理该连接超过 30 条的旧记录。
  Future<void> recordVisitedPath({
    required String id,
    required String connectionId,
    required String path,
    required int visitedAt,
  }) async {
    await transaction(() async {
      await (delete(sftpRecentPaths)..where(
            (row) =>
                row.connectionId.equals(connectionId) & row.path.equals(path),
          ))
          .go();
      await into(sftpRecentPaths).insert(
        SftpRecentPathsCompanion.insert(
          id: id,
          connectionId: connectionId,
          path: path,
          visitedAt: visitedAt,
        ),
      );
      final ids =
          await (selectOnly(sftpRecentPaths)
                ..addColumns([sftpRecentPaths.id])
                ..where(sftpRecentPaths.connectionId.equals(connectionId))
                ..orderBy([
                  OrderingTerm(
                    expression: sftpRecentPaths.visitedAt,
                    mode: OrderingMode.desc,
                  ),
                ]))
              .map((row) => row.read(sftpRecentPaths.id))
              .get();
      final staleIds = ids.whereType<String>().skip(30).toList(growable: false);
      if (staleIds.isNotEmpty) {
        await (delete(
          sftpRecentPaths,
        )..where((row) => row.id.isIn(staleIds))).go();
      }
    });
  }

  /// 读取最近路径。
  Future<List<SftpRecentPath>> loadRecentPaths(String connectionId, int limit) {
    return (select(sftpRecentPaths)
          ..where((row) => row.connectionId.equals(connectionId))
          ..orderBy([
            (row) => OrderingTerm(
              expression: row.visitedAt,
              mode: OrderingMode.desc,
            ),
          ])
          ..limit(limit))
        .get();
  }

  /// 读取收藏路径。
  Future<List<SftpFavoritePath>> loadFavoritePaths(String connectionId) {
    return (select(sftpFavoritePaths)
          ..where((row) => row.connectionId.equals(connectionId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.name),
            (row) => OrderingTerm.asc(row.path),
          ]))
        .get();
  }

  /// 按连接和路径覆盖收藏。
  Future<void> upsertFavoritePath(SftpFavoritePathsCompanion favorite) async {
    await transaction(() async {
      await (delete(sftpFavoritePaths)..where(
            (row) =>
                row.connectionId.equals(favorite.connectionId.value) &
                row.path.equals(favorite.path.value),
          ))
          .go();
      await into(sftpFavoritePaths).insertOnConflictUpdate(favorite);
    });
  }

  /// 删除收藏。
  Future<void> removeFavoritePath(String id) async {
    await (delete(sftpFavoritePaths)..where((row) => row.id.equals(id))).go();
  }

  /// 修改收藏名称。
  Future<void> renameFavoritePath({
    required String id,
    required String name,
    required int updatedAt,
  }) async {
    await (update(sftpFavoritePaths)..where((row) => row.id.equals(id))).write(
      SftpFavoritePathsCompanion(
        name: Value(name),
        updatedAt: Value(updatedAt),
      ),
    );
  }

  /// 查询连接下的单条收藏。
  Future<SftpFavoritePath?> findFavoritePath({
    required String connectionId,
    required String path,
  }) {
    return (select(sftpFavoritePaths)
          ..where(
            (row) =>
                row.connectionId.equals(connectionId) & row.path.equals(path),
          )
          ..limit(1))
        .getSingleOrNull();
  }
}
