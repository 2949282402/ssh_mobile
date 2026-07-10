part of '../app_database.dart';

@DataClassName('AgentRunMetricRow')
class AgentRunMetricsTable extends Table {
  @override
  String get tableName => 'agent_run_metrics';

  TextColumn get id => text()();
  IntColumn get startedAt => integer()();
  IntColumn get finishedAt => integer()();
  TextColumn get model => text()();
  TextColumn get helperModel => text().withDefault(const Constant(''))();
  TextColumn get auditModel => text().withDefault(const Constant(''))();
  IntColumn get promptTokens => integer().withDefault(const Constant(0))();
  IntColumn get completionTokens => integer().withDefault(const Constant(0))();
  IntColumn get totalTokens => integer().withDefault(const Constant(0))();
  IntColumn get elapsedMs => integer().withDefault(const Constant(0))();
  IntColumn get toolCalls => integer().withDefault(const Constant(0))();
  IntColumn get cacheHits => integer().withDefault(const Constant(0))();
  IntColumn get dedupBlockedCalls => integer().withDefault(const Constant(0))();
  IntColumn get ragHits => integer().withDefault(const Constant(0))();
  IntColumn get approvalCount => integer().withDefault(const Constant(0))();
  IntColumn get approvedCount => integer().withDefault(const Constant(0))();
  IntColumn get auditCount => integer().withDefault(const Constant(0))();
  IntColumn get helperFanout => integer().withDefault(const Constant(0))();
  BoolColumn get success => boolean().withDefault(const Constant(true))();
  TextColumn get selectedToolSetJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get memorySourcesJson =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
    Index(
      'idx_agent_run_metrics_finished_at',
      'CREATE INDEX idx_agent_run_metrics_finished_at '
          'ON agent_run_metrics(finished_at DESC)',
    ),
    Index(
      'idx_agent_run_metrics_model',
      'CREATE INDEX idx_agent_run_metrics_model '
          'ON agent_run_metrics(model)',
    ),
    Index(
      'idx_agent_run_metrics_success',
      'CREATE INDEX idx_agent_run_metrics_success '
          'ON agent_run_metrics(success)',
    ),
  ];
}
