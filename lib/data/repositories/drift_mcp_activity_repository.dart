part of '../../services/storage_service.dart';

extension DriftMcpActivityRepositoryOps on StorageService {
  Future<List<McpActivityRecord>> _loadMcpActivityRecords({
    int limit = 500,
  }) async {
    final database = _database;
    if (!_driftMcpActivityActive || database == null) return const [];
    final rows = await database.mcpActivityDao.loadRecent(limit: limit);
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

  Future<void> _recordMcpActivity(McpActivityRecord record) async {
    final database = _database;
    if (!_driftMcpActivityActive || database == null) return;
    await database.mcpActivityDao.insertAndTrim(
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

  Future<void> _clearMcpActivityRecords() async {
    final database = _database;
    if (!_driftMcpActivityActive || database == null) return;
    await database.mcpActivityDao.clearAll();
  }
}
