// LAN Share 历史 Repository。
//
// Module 持有数据库和 Repository，ViewModel 只接收 Repository 背后的 DAO
// 访问面；这里暂时保留 DAO 类型以降低迁移风险，后续可以继续收窄查询契约。

import '../database/lan_share_database.dart';

/// LAN 传输历史的模块级 Repository Owner。
final class LanShareHistoryRepository {
  /// 使用 Module 已打开的 LAN 数据库创建 Repository。
  LanShareHistoryRepository(this.database) : dao = database.lanHistoryDao;

  /// Repository 持有的数据库句柄引用；关闭由 [LanShareDatabase] 负责。
  final LanShareDatabase database;

  /// 当前历史 DAO，供兼容迁移中的 ViewModel 使用。
  final LanHistoryDao dao;
}
