part of '../terminal_database.dart';

/// Terminal `terminal_history` 表；只保存会话元数据，不保存原始输出。
@TableIndex.sql(
  'CREATE INDEX idx_terminal_history_updated_at '
  'ON terminal_history(updated_at DESC)',
)
@TableIndex.sql(
  'CREATE INDEX idx_terminal_history_connection_id '
  'ON terminal_history(connection_id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_terminal_history_state '
  'ON terminal_history(state)',
)
class TerminalHistory extends Table {
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
}
