part of '../app_database.dart';

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
