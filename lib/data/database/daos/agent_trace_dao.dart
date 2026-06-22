part of '../app_database.dart';

@DriftAccessor(tables: [AgentTraceEventsTable])
class AgentTraceDao extends DatabaseAccessor<AppDatabase>
    with _$AgentTraceDaoMixin {
  AgentTraceDao(super.db);

  Future<List<AgentTraceEventRow>> loadEventsForRun(String runId) {
    return (select(agentTraceEventsTable)
          ..where((row) => row.runId.equals(runId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.sequence),
            (row) => OrderingTerm.asc(row.createdAt),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .get();
  }

  Future<List<String>> loadRecentRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) {
    final safeLimit = limit.clamp(1, 200).toInt();
    return customSelect(
      'SELECT run_id FROM agent_trace_events '
      'WHERE chat_id = ? '
      'GROUP BY run_id '
      'ORDER BY MAX(created_at) DESC '
      'LIMIT ?',
      variables: [
        Variable.withString(chatId),
        Variable.withInt(safeLimit),
      ],
      readsFrom: {agentTraceEventsTable},
    ).map((row) => row.read<String>('run_id')).get();
  }

  Future<void> saveEvent(AgentTraceEventsTableCompanion event) async {
    await into(agentTraceEventsTable).insertOnConflictUpdate(event);
    await trimOldEvents();
  }

  Future<void> saveEvents(List<AgentTraceEventsTableCompanion> events) async {
    if (events.isEmpty) return;
    await batch((batch) {
      batch.insertAllOnConflictUpdate(agentTraceEventsTable, events);
    });
    await trimOldEvents();
  }

  Future<void> deleteEventsForRun(String runId) {
    return (delete(agentTraceEventsTable)
          ..where((row) => row.runId.equals(runId)))
        .go();
  }

  Future<void> deleteEventsForChat(String chatId) {
    return (delete(agentTraceEventsTable)
          ..where((row) => row.chatId.equals(chatId)))
        .go();
  }

  Future<void> trimOldEvents({
    int retainRunCount = 200,
    int maxEventsPerRun = 300,
  }) async {
    final safeRunCount = retainRunCount.clamp(1, 1000).toInt();
    final safeEventsPerRun = maxEventsPerRun.clamp(1, 2000).toInt();

    await transaction(() async {
      final runIds = await customSelect(
        'SELECT run_id FROM agent_trace_events '
        'GROUP BY run_id '
        'ORDER BY MAX(created_at) DESC',
        readsFrom: {agentTraceEventsTable},
      ).map((row) => row.read<String>('run_id')).get();

      final staleRunIds = runIds.skip(safeRunCount).toList(growable: false);
      if (staleRunIds.isNotEmpty) {
        await (delete(agentTraceEventsTable)
              ..where((row) => row.runId.isIn(staleRunIds)))
            .go();
      }

      final retainedRunIds = runIds.take(safeRunCount).toList(growable: false);
      for (final runId in retainedRunIds) {
        final eventIds = await (selectOnly(agentTraceEventsTable)
              ..addColumns([agentTraceEventsTable.id])
              ..where(agentTraceEventsTable.runId.equals(runId))
              ..orderBy([
                OrderingTerm(
                  expression: agentTraceEventsTable.sequence,
                  mode: OrderingMode.asc,
                ),
                OrderingTerm(
                  expression: agentTraceEventsTable.createdAt,
                  mode: OrderingMode.asc,
                ),
                OrderingTerm(
                  expression: agentTraceEventsTable.id,
                  mode: OrderingMode.asc,
                ),
              ]))
            .map((row) => row.read(agentTraceEventsTable.id))
            .get()
            .then((ids) => ids.whereType<String>().toList(growable: false));
        final staleEventIds =
            eventIds.skip(safeEventsPerRun).toList(growable: false);
        if (staleEventIds.isNotEmpty) {
          await (delete(agentTraceEventsTable)
                ..where((row) => row.id.isIn(staleEventIds)))
              .go();
        }
      }
    });
  }
}
