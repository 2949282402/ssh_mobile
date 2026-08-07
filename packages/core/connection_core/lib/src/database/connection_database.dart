import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'connection_database.g.dart';
part 'tables/connection_table.dart';
part 'daos/connection_dao.dart';

/// Connection 模块独立数据库的名称。
const String connectionDatabaseName = 'connection';

/// 只保存 Connection 结构和 Host Key 元数据的 Drift 数据库。
///
/// 默认构造函数使用 drift_flutter 按平台打开 `connection.sqlite`；测试通过
/// [ConnectionDatabase.forTesting] 注入内存 QueryExecutor。数据库 Owner 是
/// AppRuntime，Repository 不得自行复制或关闭它。
@DriftDatabase(tables: [ConnectionTable], daos: [ConnectionDao])
final class ConnectionDatabase extends _$ConnectionDatabase
    implements Disposable {
  /// 打开当前平台的持久化 Connection 数据库。
  factory ConnectionDatabase({QueryExecutor? executor}) {
    return ConnectionDatabase._withExecutor(
      executor ?? driftDatabase(name: connectionDatabaseName),
    );
  }

  ConnectionDatabase._withExecutor(super.executor);

  /// 使用调用方提供的 QueryExecutor，主要供单元测试使用。
  ConnectionDatabase.forTesting(super.executor);

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

  /// 关闭数据库连接，重复调用安全无副作用。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await close();
  }
}
