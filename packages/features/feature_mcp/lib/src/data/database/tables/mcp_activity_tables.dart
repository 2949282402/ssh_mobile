part of '../mcp_database.dart';

/// MCP 活动表只保存脱敏元数据，不保存 arguments、工具结果或 Token。
class McpActivityRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get occurredAt => integer()();
  TextColumn get kind => text()();
  TextColumn get method => text().nullable()();
  TextColumn get toolName => text().nullable()();
  TextColumn get outcome => text()();
  TextColumn get policyReason => text().nullable()();
  IntColumn get durationMs => integer().nullable()();

  List<Index> get indexes => [
    Index(
      'idx_mcp_activity_records_occurred_at',
      'CREATE INDEX idx_mcp_activity_records_occurred_at '
          'ON mcp_activity_records(occurred_at DESC)',
    ),
  ];
}
