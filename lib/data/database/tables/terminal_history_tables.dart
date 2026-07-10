part of '../app_database.dart';

class TerminalHistoryRecords extends Table {
  TextColumn get sessionId => text()();
  TextColumn get connectionId => text()();
  TextColumn get connectionName => text()();
  TextColumn get displayName => text()();
  TextColumn get tmuxSessionName => text().nullable()();
  TextColumn get state => text()();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId};

  List<Index> get indexes => [
    Index(
      'idx_terminal_history_updated_at',
      'CREATE INDEX idx_terminal_history_updated_at '
          'ON terminal_history_records(updated_at DESC)',
    ),
    Index(
      'idx_terminal_history_connection_id',
      'CREATE INDEX idx_terminal_history_connection_id '
          'ON terminal_history_records(connection_id)',
    ),
    Index(
      'idx_terminal_history_state',
      'CREATE INDEX idx_terminal_history_state '
          'ON terminal_history_records(state)',
    ),
  ];
}
