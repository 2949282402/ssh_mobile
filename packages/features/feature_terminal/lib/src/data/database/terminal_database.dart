// Terminal 独立 Drift 数据库。
//
// 数据库 Owner 是 TerminalModule；Repository 不创建或关闭数据库。Terminal
// 历史数据已经由本 Module 独立持有，不再依赖旧统一业务数据库。

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'terminal_database.g.dart';
part 'tables/terminal_history_table.dart';
part 'daos/terminal_history_dao.dart';

/// Terminal 数据库的稳定文件名。
const String terminalDatabaseName = 'terminal';

/// 只包含 Terminal 元数据的数据库。
@DriftDatabase(tables: [TerminalHistory], daos: [TerminalHistoryDao])
final class TerminalDatabase extends _$TerminalDatabase implements Disposable {
  /// 打开当前平台的 terminal.db。
  factory TerminalDatabase({QueryExecutor? executor}) {
    return TerminalDatabase._withExecutor(
      executor ?? driftDatabase(name: terminalDatabaseName),
    );
  }

  TerminalDatabase._withExecutor(super.executor);

  /// 使用测试 QueryExecutor 创建内存数据库。
  TerminalDatabase.forTesting(super.executor);

  bool _disposed = false;

  /// 数据库 Owner 是否已经执行幂等关闭。
  bool get isDisposed => _disposed;

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// 关闭数据库；重复调用安全。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await close();
  }
}
