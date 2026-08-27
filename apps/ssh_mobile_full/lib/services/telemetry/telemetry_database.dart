// App Scope 遥测 SQLite 数据库入口。
//
// 遥测属于 App 基础设施，不依赖业务数据库。本文件声明独立的 `telemetry.db`
// 数据库，供 [DriftTelemetryStorage] 做本地持久化；测试使用内存执行器。

import 'package:drift/drift.dart';

import 'telemetry_database/telemetry_database_connection.dart';

part 'telemetry_database.g.dart';
part 'telemetry_database/tables/telemetry_records.dart';
part 'telemetry_database/daos/telemetry_records_dao.dart';

/// 遥测本地 SQLite 数据库的唯一句柄 Owner。
///
/// 数据库句柄由 [DriftTelemetryStorage] 显式创建并关闭，避免业务层重复释放
/// 同一个连接。
@DriftDatabase(tables: [TelemetryRecords], daos: [TelemetryRecordsDao])
final class TelemetryDatabase extends _$TelemetryDatabase
    implements AppDisposable {
  /// 打开当前平台的独立遥测数据库。
  factory TelemetryDatabase({QueryExecutor? executor}) {
    return TelemetryDatabase._withExecutor(
      executor ?? openTelemetryDatabaseConnection(),
    );
  }

  TelemetryDatabase._withExecutor(super.executor);

  /// 使用测试执行器创建隔离的内存数据库。
  TelemetryDatabase.forTesting([QueryExecutor? executor])
    : super(executor ?? openTelemetryTestDatabaseConnection());

  bool _disposed = false;

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// 关闭数据库；重复调用安全，便于 AppRuntime 的错误收集式释放。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await close();
  }
}

/// 与 Drift Database 生命周期无关的最小释放契约。
abstract interface class AppDisposable {
  Future<void> dispose();
}
