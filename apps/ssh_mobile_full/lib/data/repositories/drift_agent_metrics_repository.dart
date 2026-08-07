part of '../../services/storage_service.dart';

extension DriftAgentMetricsRepositoryOps on StorageService {
  Future<List<AgentRunMetrics>> _loadDriftAgentRunMetrics() async {
    final database = _database;
    if (!_driftAgentMetricsActive || database == null) return const [];
    final rows = await database.agentMetricsDao.loadMetrics();
    final metrics = rows.map(_agentRunMetricsFromDrift).toList(growable: false);
    return _agentRunMetricsCache = List.unmodifiable(metrics);
  }

  Future<void> _saveDriftAgentRunMetrics(AgentRunMetrics metrics) async {
    final database = _database;
    if (!_driftAgentMetricsActive || database == null) return;
    await database.agentMetricsDao.saveMetric(
      _agentRunMetricsToCompanion(metrics),
    );
    final current = _agentRunMetricsCache ?? const <AgentRunMetrics>[];
    final next = <AgentRunMetrics>[
      metrics,
      ...current.where((item) => item.id != metrics.id),
    ];
    if (next.length > 200) {
      next.removeRange(200, next.length);
    }
    _agentRunMetricsCache = List.unmodifiable(next);
  }

  Future<void> _replaceDriftAgentRunMetrics(
    List<AgentRunMetrics> metrics,
  ) async {
    final database = _database;
    if (!_driftReady || database == null) return;
    final ordered = [...metrics]
      ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
    await database.agentMetricsDao.replaceAllMetrics(
      ordered.map(_agentRunMetricsToCompanion).toList(growable: false),
    );
    _agentRunMetricsCache = List.unmodifiable(ordered.take(200));
  }

  db.AgentRunMetricsTableCompanion _agentRunMetricsToCompanion(
    AgentRunMetrics metrics,
  ) {
    return db.AgentRunMetricsTableCompanion(
      id: drift.Value(metrics.id),
      startedAt: drift.Value(_toDbMillis(metrics.startedAt)),
      finishedAt: drift.Value(_toDbMillis(metrics.finishedAt)),
      model: drift.Value(metrics.model),
      helperModel: drift.Value(metrics.helperModel),
      auditModel: drift.Value(metrics.auditModel),
      promptTokens: drift.Value(metrics.promptTokens),
      completionTokens: drift.Value(metrics.completionTokens),
      totalTokens: drift.Value(metrics.totalTokens),
      elapsedMs: drift.Value(metrics.elapsedMs),
      toolCalls: drift.Value(metrics.toolCalls),
      cacheHits: drift.Value(metrics.cacheHits),
      dedupBlockedCalls: drift.Value(metrics.dedupBlockedCalls),
      ragHits: drift.Value(metrics.ragHits),
      approvalCount: drift.Value(metrics.approvalCount),
      approvedCount: drift.Value(metrics.approvedCount),
      auditCount: drift.Value(metrics.auditCount),
      helperFanout: drift.Value(metrics.helperFanout),
      success: drift.Value(metrics.success),
      selectedToolSetJson: drift.Value(jsonEncode(metrics.selectedToolSet)),
      memorySourcesJson: drift.Value(jsonEncode(metrics.memorySources)),
    );
  }

  AgentRunMetrics _agentRunMetricsFromDrift(db.AgentRunMetricRow row) {
    return AgentRunMetrics(
      id: row.id,
      startedAt: _fromDbMillis(row.startedAt),
      finishedAt: _fromDbMillis(row.finishedAt),
      model: row.model,
      helperModel: row.helperModel,
      auditModel: row.auditModel,
      promptTokens: row.promptTokens,
      completionTokens: row.completionTokens,
      totalTokens: row.totalTokens,
      elapsedMs: row.elapsedMs,
      toolCalls: row.toolCalls,
      cacheHits: row.cacheHits,
      dedupBlockedCalls: row.dedupBlockedCalls,
      ragHits: row.ragHits,
      approvalCount: row.approvalCount,
      approvedCount: row.approvedCount,
      auditCount: row.auditCount,
      helperFanout: row.helperFanout,
      success: row.success,
      selectedToolSet: _decodeStringList(row.selectedToolSetJson),
      memorySources: _decodeStringList(row.memorySourcesJson),
    );
  }

  List<String> _decodeStringList(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! List) return const [];
    return decoded.map((item) => '$item').toList(growable: false);
  }
}
