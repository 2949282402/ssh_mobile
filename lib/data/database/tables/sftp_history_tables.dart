part of '../app_database.dart';

class SftpRecentPaths extends Table {
  TextColumn get id => text()();
  TextColumn get connectionId => text()();
  TextColumn get path => text()();
  IntColumn get visitedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
        Index(
          'idx_sftp_recent_connection_visited',
          'CREATE INDEX idx_sftp_recent_connection_visited '
              'ON sftp_recent_paths(connection_id, visited_at DESC)',
        ),
        Index(
          'idx_sftp_recent_connection_path',
          'CREATE INDEX idx_sftp_recent_connection_path '
              'ON sftp_recent_paths(connection_id, path)',
        ),
      ];
}

class SftpFavoritePaths extends Table {
  TextColumn get id => text()();
  TextColumn get connectionId => text()();
  TextColumn get path => text()();
  TextColumn get name => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
        Index(
          'idx_sftp_favorite_connection',
          'CREATE INDEX idx_sftp_favorite_connection '
              'ON sftp_favorite_paths(connection_id)',
        ),
        Index(
          'idx_sftp_favorite_connection_path',
          'CREATE INDEX idx_sftp_favorite_connection_path '
              'ON sftp_favorite_paths(connection_id, path)',
        ),
      ];
}
