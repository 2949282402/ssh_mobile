// MCP Feature 的独立 Drift 数据库。
//
// MCP 活动记录属于 MCP Module，不再写入 AppDatabase。数据库异常必须向上抛出，
// 不能为了继续启动而静默退回内存实现。

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'mcp_database.g.dart';
part 'tables/mcp_activity_tables.dart';
part 'daos/mcp_activity_dao.dart';

/// Drift native 数据库名；平台文件名由 Drift 负责补充扩展名。
const mcpDatabaseName = 'mcp';

/// MCP 模块的数据库工厂类型，供 AppRuntime 测试注入内存执行器。
typedef McpDatabaseFactory = McpDatabase Function();

@DriftDatabase(tables: [McpActivityRecords], daos: [McpActivityDao])
final class McpDatabase extends _$McpDatabase implements Disposable {
  /// 创建生产数据库；关闭责任由 [McpModule] 承担。
  McpDatabase() : super(driftDatabase(name: mcpDatabaseName));

  /// 使用测试执行器，避免测试访问平台文件系统。
  McpDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) async {
      await migrator.createAll();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  bool _disposed = false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await close();
  }
}
