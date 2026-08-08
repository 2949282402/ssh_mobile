// MCP 活动 Repository；它是 MCP Service 与 mcp.db 之间的唯一持久化边界。

import 'package:drift/drift.dart' as drift;

import '../../domain/mcp_activity.dart';
import '../database/mcp_database.dart' as db;

/// 基于 Drift 的活动 Repository 实现。
final class DriftMcpActivityRepository implements McpActivityRepository {
  DriftMcpActivityRepository(this._database);

  final db.McpDatabase _database;

  @override
  Future<List<McpActivityRecord>> loadMcpActivityRecords({
    int limit = 500,
  }) async {
    final rows = await _database.mcpActivityDao.loadRecent(limit: limit);
    return List.unmodifiable([
      for (final row in rows)
        McpActivityRecord(
          id: row.id,
          occurredAt: _fromDbMillis(row.occurredAt),
          kind: McpActivityKind.values.byName(row.kind),
          method: row.method,
          toolName: row.toolName,
          outcome: McpActivityOutcome.values.byName(row.outcome),
          policyReason: row.policyReason,
          durationMs: row.durationMs,
        ),
    ]);
  }

  @override
  Future<void> recordMcpActivity(McpActivityRecord record) {
    return _database.mcpActivityDao.insertAndTrim(
      db.McpActivityRecordsCompanion.insert(
        occurredAt: _toDbMillis(record.occurredAt),
        kind: record.kind.name,
        method: drift.Value(record.method),
        toolName: drift.Value(record.toolName),
        outcome: record.outcome.name,
        policyReason: drift.Value(record.policyReason),
        durationMs: drift.Value(record.durationMs),
      ),
    );
  }

  @override
  Future<void> clearMcpActivityRecords() => _database.mcpActivityDao.clearAll();

  int _toDbMillis(DateTime dateTime) => dateTime.toUtc().millisecondsSinceEpoch;

  DateTime _fromDbMillis(int millis) =>
      DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
}
