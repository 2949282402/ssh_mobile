part of '../app_database.dart';

@DataClassName('AgentTraceEventRow')
class AgentTraceEventsTable extends Table {
  @override
  String get tableName => 'agent_trace_events';

  TextColumn get id => text()();
  TextColumn get runId => text()();
  TextColumn get chatId => text()();
  IntColumn get createdAt => integer()();
  IntColumn get sequence => integer()();
  TextColumn get kind => text()();
  TextColumn get title => text()();
  TextColumn get contentJson => text()();
  TextColumn get toolName => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('info'))();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get parentEventId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
        Index(
          'idx_agent_trace_run_sequence',
          'CREATE INDEX idx_agent_trace_run_sequence '
              'ON agent_trace_events(run_id, sequence ASC)',
        ),
        Index(
          'idx_agent_trace_chat_created',
          'CREATE INDEX idx_agent_trace_chat_created '
              'ON agent_trace_events(chat_id, created_at DESC)',
        ),
        Index(
          'idx_agent_trace_kind',
          'CREATE INDEX idx_agent_trace_kind '
              'ON agent_trace_events(kind)',
        ),
      ];
}
