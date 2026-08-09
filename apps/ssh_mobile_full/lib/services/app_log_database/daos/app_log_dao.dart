part of '../../app_log_database.dart';

/// App 日志表的最小持久化访问面。
@DriftAccessor(tables: [AppLogRecords])
class AppLogDao extends DatabaseAccessor<AppLogDatabase> with _$AppLogDaoMixin {
  AppLogDao(super.db);

  /// 按写入 ID 从旧到新读取日志，供内存快照恢复使用。
  Future<List<AppLogRecord>> getAllLogs() {
    return (select(appLogRecords)..orderBy([
          (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
        ]))
        .get();
  }

  /// 插入一条已经脱敏的日志记录。
  Future<int> insertLog(AppLogRecordsCompanion record) {
    return into(appLogRecords).insert(record);
  }

  /// 只保留最新的日志，限制数据库增长。
  Future<void> pruneOldLogs() async {
    await customStatement(
      'DELETE FROM app_log_records WHERE id NOT IN '
      '(SELECT id FROM app_log_records ORDER BY id DESC LIMIT 1000)',
    );
  }

  /// 删除指定日志。
  Future<void> deleteLogs(Set<int> ids) {
    return (delete(appLogRecords)..where((t) => t.id.isIn(ids))).go();
  }

  /// 清空日志表。
  Future<void> clearAllLogs() {
    return delete(appLogRecords).go();
  }
}
