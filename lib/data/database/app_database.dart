import 'package:drift/drift.dart';

import 'database_connection.dart';

part 'app_database.g.dart';
part 'tables/ai_chat_tables.dart';
part 'tables/agent_metrics_tables.dart';
part 'tables/agent_trace_tables.dart';
part 'tables/lan_history_tables.dart';
part 'tables/migration_meta_table.dart';
part 'tables/mcp_activity_tables.dart';
part 'tables/playbook_tables.dart';
part 'tables/sftp_history_tables.dart';
part 'tables/terminal_history_tables.dart';
part 'tables/app_log_tables.dart';
part 'daos/ai_chat_dao.dart';
part 'daos/agent_metrics_dao.dart';
part 'daos/agent_trace_dao.dart';
part 'daos/lan_history_dao.dart';
part 'daos/migration_meta_dao.dart';
part 'daos/mcp_activity_dao.dart';
part 'daos/playbook_dao.dart';
part 'daos/sftp_history_dao.dart';
part 'daos/terminal_history_dao.dart';
part 'daos/app_log_dao.dart';

@DriftDatabase(
  tables: [
    MigrationMeta,
    AiChats,
    AiChatMessages,
    AgentRunMetricsTable,
    AgentTraceEventsTable,
    TerminalHistoryRecords,
    Playbooks,
    PlaybookRuns,
    PlaybookRunSteps,
    SftpRecentPaths,
    SftpFavoritePaths,
    LanTransferRecords,
    AppLogRecords,
    McpActivityRecords,
  ],
  daos: [
    MigrationMetaDao,
    AiChatDao,
    AgentMetricsDao,
    AgentTraceDao,
    TerminalHistoryDao,
    PlaybookDao,
    SftpHistoryDao,
    LanHistoryDao,
    AppLogDao,
    McpActivityDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  // Drift activity metadata is intentionally non-sensitive and queryable.
  AppDatabase({QueryExecutor? executor})
    : super(_configureExecutor(executor ?? openDatabaseConnection()));

  AppDatabase.forTesting()
    : super(_configureExecutor(openTestDatabaseConnection()));

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(agentTraceEventsTable);
        await m.addColumn(aiChatMessages, aiChatMessages.agentRunId);
      }
      if (from < 3) {
        await m.createTable(lanTransferRecords);
      }
      if (from < 4) {
        await m.createTable(appLogRecords);
      }
      if (from < 5) {
        await m.createTable(mcpActivityRecords);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  static QueryExecutor _configureExecutor(QueryExecutor executor) {
    if (isFlutterTestEnvironment) {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    }
    return executor;
  }
}
