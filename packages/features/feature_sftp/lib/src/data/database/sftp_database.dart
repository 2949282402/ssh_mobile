// SFTP Feature 的独立 Drift 数据库。
//
// 数据库只保存路径历史、收藏和未来可扩展的传输元数据，不保存密码、私钥
// 或 Token。生命周期由 SftpModule 独占，Repository 不负责关闭句柄。

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'sftp_database.g.dart';
part 'tables/sftp_path_tables.dart';
part 'daos/sftp_path_history_dao.dart';

/// SFTP 数据库文件名；Drift 会在平台目录中生成 sftp.db。
const String sftpDatabaseName = 'sftp';

/// 只包含 SFTP 自有结构化数据的数据库。
@DriftDatabase(
  tables: [SftpRecentPaths, SftpFavoritePaths],
  daos: [SftpPathHistoryDao],
)
final class SftpDatabase extends _$SftpDatabase implements Disposable {
  /// 打开当前平台的 sftp.db。
  factory SftpDatabase({QueryExecutor? executor}) {
    return SftpDatabase._withExecutor(
      executor ?? driftDatabase(name: sftpDatabaseName),
    );
  }

  SftpDatabase._withExecutor(super.executor);

  /// 使用测试 QueryExecutor 创建内存数据库。
  SftpDatabase.forTesting(super.executor);

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
