part of '../app_database.dart';

@DriftAccessor(tables: [SftpRecentPaths, SftpFavoritePaths])
class SftpHistoryDao extends DatabaseAccessor<AppDatabase>
    with _$SftpHistoryDaoMixin {
  SftpHistoryDao(super.db);

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
      final orderedIds =
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
              .get()
              .then((ids) => ids.whereType<String>().toList(growable: false));
      final staleIds = orderedIds.skip(30).toList(growable: false);
      if (staleIds.isNotEmpty) {
        await (delete(
          sftpRecentPaths,
        )..where((row) => row.id.isIn(staleIds))).go();
      }
    });
  }

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

  Future<List<SftpFavoritePath>> loadFavoritePaths(String connectionId) {
    return (select(sftpFavoritePaths)
          ..where((row) => row.connectionId.equals(connectionId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.name),
            (row) => OrderingTerm.asc(row.path),
          ]))
        .get();
  }

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

  Future<void> removeFavoritePath(String id) async {
    await (delete(sftpFavoritePaths)..where((row) => row.id.equals(id))).go();
  }

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

  Future<void> replaceAll({
    required List<SftpRecentPathsCompanion> recentPaths,
    required List<SftpFavoritePathsCompanion> favoritePaths,
  }) async {
    await transaction(() async {
      await delete(sftpRecentPaths).go();
      await delete(sftpFavoritePaths).go();
      await batch((batch) {
        if (recentPaths.isNotEmpty) {
          batch.insertAll(sftpRecentPaths, recentPaths);
        }
        if (favoritePaths.isNotEmpty) {
          batch.insertAll(sftpFavoritePaths, favoritePaths);
        }
      });
    });
  }
}
