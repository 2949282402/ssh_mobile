part of '../app_database.dart';

@DriftAccessor(tables: [AppLogRecords])
class AppLogDao extends DatabaseAccessor<AppDatabase> with _$AppLogDaoMixin {
  AppLogDao(super.db);

  Future<List<AppLogRecord>> getAllLogs() {
    return (select(appLogRecords)..orderBy([
          (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
        ]))
        .get();
  }

  Future<int> insertLog(AppLogRecordsCompanion record) {
    return into(appLogRecords).insert(record);
  }

  Future<void> pruneOldLogs() async {
    await customStatement(
      'DELETE FROM app_log_records WHERE id NOT IN '
      '(SELECT id FROM app_log_records ORDER BY id DESC LIMIT 1000)',
    );
  }

  Future<void> deleteLogs(Set<int> ids) {
    return (delete(appLogRecords)..where((t) => t.id.isIn(ids))).go();
  }

  Future<void> clearAllLogs() {
    return delete(appLogRecords).go();
  }
}
