part of '../../services/storage_service.dart';

extension DriftAgentTraceRepositoryOps on StorageService {
  Future<List<AgentTraceEvent>> _loadAgentTraceEvents(String runId) async {
    final trimmedRunId = runId.trim();
    if (trimmedRunId.isEmpty) return const [];
    final cached = _agentTraceEventsCache[trimmedRunId];
    if (cached != null) return cached;
    final database = _database;
    if (!_driftAgentTraceActive || database == null) return const [];
    final rows = await database.agentTraceDao.loadEventsForRun(trimmedRunId);
    final events = <AgentTraceEvent>[];
    for (final row in rows) {
      events.add(await _agentTraceEventFromDrift(row));
    }
    final ordered = List<AgentTraceEvent>.unmodifiable(events);
    _agentTraceEventsCache[trimmedRunId] = ordered;
    return ordered;
  }

  Future<List<String>> _loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) async {
    final database = _database;
    if (!_driftAgentTraceActive || database == null) return const [];
    return database.agentTraceDao.loadRecentRunIdsForChat(chatId, limit: limit);
  }

  Future<void> _saveAgentTraceEvent(AgentTraceEvent event) async {
    await _saveAgentTraceEvents([event]);
  }

  Future<void> _saveAgentTraceEvents(List<AgentTraceEvent> events) async {
    if (events.isEmpty) return;
    final database = _database;
    if (!_driftAgentTraceActive || database == null) return;
    final companions = <db.AgentTraceEventsTableCompanion>[];
    final perRunCounts = <String, int>{};
    for (final event in events) {
      final count = perRunCounts[event.runId] ?? 0;
      if (count >= agentTraceEventsPerRunLimit) continue;
      perRunCounts[event.runId] = count + 1;
      companions.add(await _agentTraceEventToCompanion(event));
    }
    if (companions.isEmpty) return;
    await database.agentTraceDao.saveEvents(companions);
    // DAO retention can remove runs beyond the ones in this batch.
    _agentTraceEventsCache.clear();
  }

  Future<void> _deleteAgentTraceEvents(String runId) async {
    final trimmedRunId = runId.trim();
    if (trimmedRunId.isEmpty) return;
    final database = _database;
    if (!_driftAgentTraceActive || database == null) return;
    await database.agentTraceDao.deleteEventsForRun(trimmedRunId);
    _agentTraceEventsCache.remove(trimmedRunId);
  }

  Future<db.AgentTraceEventsTableCompanion> _agentTraceEventToCompanion(
    AgentTraceEvent event,
  ) async {
    final contentJson = jsonEncode({
      'content': event.content,
      'truncated': event.truncated,
    });
    return db.AgentTraceEventsTableCompanion(
      id: drift.Value(event.id),
      runId: drift.Value(event.runId),
      chatId: drift.Value(event.chatId),
      createdAt: drift.Value(_toDbMillis(event.createdAt)),
      sequence: drift.Value(event.sequence),
      kind: drift.Value(event.kind),
      title: drift.Value(event.title),
      contentJson: drift.Value(await _encryptDriftText(contentJson)),
      toolName: drift.Value(event.toolName),
      status: drift.Value(event.status),
      durationMs: drift.Value(event.durationMs),
      parentEventId: drift.Value(event.parentEventId),
    );
  }

  Future<AgentTraceEvent> _agentTraceEventFromDrift(
    db.AgentTraceEventRow row,
  ) async {
    final decodedContentJson = await _decryptDriftText(row.contentJson);
    String content = '';
    var truncated = false;
    try {
      final decoded = jsonDecode(decodedContentJson);
      if (decoded is Map) {
        content = decoded['content'] as String? ?? '';
        truncated = decoded['truncated'] as bool? ?? false;
      } else if (decoded is String) {
        content = decoded;
      }
    } catch (_) {
      content = decodedContentJson;
    }
    return AgentTraceEvent(
      id: row.id,
      runId: row.runId,
      chatId: row.chatId,
      createdAt: _fromDbMillis(row.createdAt),
      sequence: row.sequence,
      kind: row.kind,
      title: row.title,
      content: content,
      toolName: row.toolName,
      status: row.status,
      durationMs: row.durationMs,
      parentEventId: row.parentEventId,
      truncated: truncated,
    );
  }
}
