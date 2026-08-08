// Playbook Feature 的独立 Drift 数据库。
//
// Module 独占本数据库，避免 Playbook 继续把成长型数据写入 AppDatabase。
// 数据库失败必须向上抛出，不能静默退回内存数据库。

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'playbook_database.g.dart';
part 'tables/playbook_tables.dart';
part 'daos/playbook_dao.dart';

/// Native 文件名；Drift native 默认生成 `playbook.sqlite`。
const playbookDatabaseName = 'playbook';

/// 测试可注入的数据库工厂。
typedef PlaybookDatabaseFactory = PlaybookDatabase Function();

@DriftDatabase(
  tables: [Playbooks, PlaybookRuns, PlaybookRunSteps],
  daos: [PlaybookDao],
)
final class PlaybookDatabase extends _$PlaybookDatabase implements Disposable {
  /// 创建生产数据库；文件句柄由 Module 关闭。
  PlaybookDatabase()
    : super(_configureExecutor(driftDatabase(name: playbookDatabaseName)));

  /// 使用测试执行器创建数据库，不触碰平台文件系统。
  PlaybookDatabase.forTesting(QueryExecutor executor)
    : super(_configureExecutor(executor));

  static QueryExecutor _configureExecutor(QueryExecutor executor) {
    return executor;
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
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
