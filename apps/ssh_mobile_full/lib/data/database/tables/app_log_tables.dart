part of '../app_database.dart';

class AppLogRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get time => integer()(); // timestamp in milliseconds since epoch
  TextColumn get level => text()();
  TextColumn get message => text()();
  TextColumn get sourceLocation => text().nullable()();
  TextColumn get stackTrace => text().nullable()();
  TextColumn get details => text().nullable()();

  List<Index> get indexes => [
    Index(
      'idx_app_log_time',
      'CREATE INDEX idx_app_log_time ON app_log_records(time DESC)',
    ),
  ];
}
