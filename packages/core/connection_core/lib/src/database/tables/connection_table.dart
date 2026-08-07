part of '../connection_database.dart';

/// Connection 结构化表，只包含可查询的非敏感字段。
class ConnectionTable extends Table {
  /// 稳定的连接业务 id，作为主键而不是 SQLite 自增 id。
  TextColumn get id => text()();

  /// 用户可见名称。
  TextColumn get name => text()();

  /// SSH 主机和端口。
  TextColumn get host => text()();
  IntColumn get port => integer()();

  /// SSH 登录用户；密码和私钥不在本表。
  TextColumn get username => text()();
  TextColumn get authMethod => text()();

  /// 终端和保活配置。
  IntColumn get terminalWidth => integer()();
  IntColumn get terminalHeight => integer()();
  BoolColumn get keepAlive => boolean()();
  IntColumn get keepAliveInterval => integer()();
  TextColumn get launchMode => text()();
  TextColumn get serverPlatform => text()();
  IntColumn get tmuxAutoDeleteSeconds => integer()();

  /// Host Key 信任元数据。
  TextColumn get hostKeyFingerprint => text().nullable()();
  TextColumn get hostKeyAlgorithm => text().nullable()();
  IntColumn get hostKeyTrustedAt => integer().nullable()();

  /// Jump Host 和分组配置。
  TextColumn get jumpHost => text().nullable()();
  IntColumn get jumpPort => integer().nullable()();
  TextColumn get jumpUsername => text().nullable()();
  TextColumn get group => text().nullable()();

  /// 创建/更新时间使用 UTC 毫秒，避免平台时区改变排序语义。
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  /// 列表拖拽顺序；不依赖数据库隐含 rowid。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
