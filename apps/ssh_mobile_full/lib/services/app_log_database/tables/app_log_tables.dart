part of '../../app_log_database.dart';

/// App 诊断日志表；日志内容已由 AppLogService 在写入前脱敏。
// Drift replaces this declaration with a generated TableInfo subclass; the
// column builders below are declarative schema input rather than executable
// business logic.
// coverage:ignore-start
@TableIndex.sql('CREATE INDEX idx_app_log_time ON app_log_records(time DESC)')
class AppLogRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get time => integer()();
  TextColumn get level => text()();
  TextColumn get message => text()();
  TextColumn get sourceLocation => text().nullable()();
  TextColumn get stackTrace => text().nullable()();
  TextColumn get details => text().nullable()();
}
// coverage:ignore-end
