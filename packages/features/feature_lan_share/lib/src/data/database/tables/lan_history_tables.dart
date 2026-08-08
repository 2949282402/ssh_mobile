part of '../lan_share_database.dart';

/// LAN 传输历史表；敏感文本由 ViewModel 在写入前通过 DataProtection Port
/// 加密，密钥和 PIN 不进入此表。
class LanTransferRecords extends Table {
  TextColumn get id => text()();
  TextColumn get senderId => text()();
  TextColumn get senderAlias => text()();
  TextColumn get receiverId => text()();
  TextColumn get payloadType => text()();
  TextColumn get textContent => text().nullable()();
  TextColumn get fileName => text().nullable()();
  IntColumn get fileSize => integer().withDefault(const Constant(0))();
  TextColumn get localPath => text().nullable()();
  TextColumn get manifestJson => text().nullable()();
  TextColumn get status => text()();
  IntColumn get bytesTransferred => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  BoolColumn get isIncoming => boolean().withDefault(const Constant(false))();
  BoolColumn get isRecalled => boolean().withDefault(const Constant(false))();
  TextColumn get sftpServerId => text().nullable()();
  TextColumn get sftpRemotePath => text().nullable()();
  TextColumn get transport => text().nullable()();
  TextColumn get routeType => text().nullable()();
  IntColumn get avgRtt => integer().nullable()();
  IntColumn get bytesTotal => integer().nullable()();
  TextColumn get failureReason => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
    Index(
      'idx_lan_share_transfer_created',
      'CREATE INDEX idx_lan_share_transfer_created '
          'ON lan_transfer_records(created_at DESC)',
    ),
  ];
}
