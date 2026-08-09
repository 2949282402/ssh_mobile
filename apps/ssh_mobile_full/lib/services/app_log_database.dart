// App Scope 日志数据库入口。
//
// 日志属于 App 基础设施，不属于任何 Feature；本文件只声明独立的
// `app_logs` 数据库及其生命周期，避免 App 日志重新依赖统一业务数据库。

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';

import 'app_log_database_connection.dart';

part 'app_log_database.g.dart';
part 'app_log_database/tables/app_log_tables.dart';
part 'app_log_database/daos/app_log_dao.dart';

/// App 日志数据库及 DAO 的唯一句柄 Owner。
///
/// AppLogService 只负责日志门面和写入队列；数据库句柄由调用方显式
/// 绑定并由该类关闭，避免 Repository 或 UI 重复释放同一个连接。
@DriftDatabase(tables: [AppLogRecords], daos: [AppLogDao])
final class AppLogDatabase extends _$AppLogDatabase implements Disposable {
  /// 打开当前平台的独立 App 日志数据库。
  factory AppLogDatabase({QueryExecutor? executor}) {
    return AppLogDatabase._withExecutor(
      executor ?? openAppLogDatabaseConnection(),
    );
  }

  AppLogDatabase._withExecutor(super.executor);

  /// 使用测试执行器创建隔离的内存数据库。
  AppLogDatabase.forTesting([QueryExecutor? executor])
    : super(executor ?? openAppLogTestDatabaseConnection());

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
