// LAN Share 独立 Drift 数据库。
//
// 数据库只承载传输历史和不含密钥、Token 的配对元数据；Module 独占并关闭
// 数据库句柄，ViewModel 和 Repository 不负责重复 close。

import 'package:app_core/app_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'lan_share_database.g.dart';
part 'tables/lan_history_tables.dart';
part 'tables/lan_pairing_metadata_tables.dart';
part 'daos/lan_history_dao.dart';
part 'daos/lan_pairing_metadata_dao.dart';

/// Drift 使用的 LAN Share 数据库名称，对应平台文件 `lan_share.sqlite`。
const String lanShareDatabaseName = 'lan_share';

/// LAN Share 数据库及其 DAO 的唯一句柄 Owner。
@DriftDatabase(
  tables: [LanTransferRecords, LanPairingMetadata],
  daos: [LanHistoryDao, LanPairingMetadataDao],
)
final class LanShareDatabase extends _$LanShareDatabase implements Disposable {
  /// 打开平台默认路径中的独立数据库。
  factory LanShareDatabase({QueryExecutor? executor}) {
    return LanShareDatabase._withExecutor(
      executor ?? driftDatabase(name: lanShareDatabaseName),
    );
  }

  LanShareDatabase._withExecutor(super.executor);

  /// 使用测试 QueryExecutor 创建数据库。
  LanShareDatabase.forTesting(super.executor);

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

  /// 关闭数据库；重复调用安全。
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await close();
  }
}
