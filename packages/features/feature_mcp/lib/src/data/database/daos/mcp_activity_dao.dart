part of '../mcp_database.dart';

/// MCP 活动 DAO 统一限制查询和保留数量，避免本地日志无限增长。
@DriftAccessor(tables: [McpActivityRecords])
class McpActivityDao extends DatabaseAccessor<McpDatabase>
    with _$McpActivityDaoMixin {
  McpActivityDao(super.db);

  Future<List<McpActivityRecord>> loadRecent({int limit = 500}) {
    final safeLimit = limit.clamp(1, 500).toInt();
    return (select(mcpActivityRecords)
          ..orderBy([(row) => OrderingTerm.desc(row.occurredAt)])
          ..limit(safeLimit))
        .get();
  }

  Future<void> insertAndTrim(McpActivityRecordsCompanion record) async {
    await into(mcpActivityRecords).insert(record);
    await customStatement(
      'DELETE FROM mcp_activity_records WHERE id NOT IN '
      '(SELECT id FROM mcp_activity_records '
      'ORDER BY occurred_at DESC, id DESC LIMIT 500)',
    );
  }

  Future<void> clearAll() => delete(mcpActivityRecords).go();
}
