part of '../app_database.dart';

@DriftAccessor(tables: [AgentRunMetricsTable])
class AgentMetricsDao extends DatabaseAccessor<AppDatabase>
    with _$AgentMetricsDaoMixin {
  AgentMetricsDao(super.db);

  Future<List<AgentRunMetricRow>> loadMetrics() {
    return (select(agentRunMetricsTable)..orderBy([
          (row) =>
              OrderingTerm(expression: row.finishedAt, mode: OrderingMode.desc),
        ]))
        .get();
  }

  Future<void> saveMetric(AgentRunMetricsTableCompanion metric) async {
    await into(agentRunMetricsTable).insertOnConflictUpdate(metric);
    final orderedIds =
        await (selectOnly(agentRunMetricsTable)
              ..addColumns([agentRunMetricsTable.id])
              ..orderBy([
                OrderingTerm(
                  expression: agentRunMetricsTable.finishedAt,
                  mode: OrderingMode.desc,
                ),
              ]))
            .map((row) => row.read(agentRunMetricsTable.id))
            .get()
            .then((ids) => ids.whereType<String>().toList(growable: false));
    final staleIds = orderedIds.skip(200).toList(growable: false);
    if (staleIds.isNotEmpty) {
      await (delete(
        agentRunMetricsTable,
      )..where((row) => row.id.isIn(staleIds))).go();
    }
  }

  Future<void> replaceAllMetrics(
    List<AgentRunMetricsTableCompanion> metrics,
  ) async {
    await transaction(() async {
      await delete(agentRunMetricsTable).go();
      final retained = metrics.take(200).toList(growable: false);
      if (retained.isNotEmpty) {
        await batch((batch) => batch.insertAll(agentRunMetricsTable, retained));
      }
    });
  }
}
