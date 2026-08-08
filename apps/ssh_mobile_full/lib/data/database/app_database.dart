import 'package:drift/drift.dart';

import 'database_connection.dart';

part 'app_database.g.dart';
part 'tables/lan_history_tables.dart';
part 'tables/playbook_tables.dart';
part 'tables/sftp_history_tables.dart';
part 'tables/terminal_history_tables.dart';
part 'tables/app_log_tables.dart';
part 'daos/lan_history_dao.dart';
part 'daos/playbook_dao.dart';
part 'daos/sftp_history_dao.dart';
part 'daos/terminal_history_dao.dart';
part 'daos/app_log_dao.dart';

@DriftDatabase(
  tables: [
    TerminalHistoryRecords,
    Playbooks,
    PlaybookRuns,
    PlaybookRunSteps,
    SftpRecentPaths,
    SftpFavoritePaths,
    LanTransferRecords,
    AppLogRecords,
  ],
  daos: [
    TerminalHistoryDao,
    PlaybookDao,
    SftpHistoryDao,
    LanHistoryDao,
    AppLogDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  // Drift activity metadata is intentionally non-sensitive and queryable.
  AppDatabase({QueryExecutor? executor})
    : super(_configureExecutor(executor ?? openDatabaseConnection()));

  AppDatabase.forTesting()
    : super(_configureExecutor(openTestDatabaseConnection()));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
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
