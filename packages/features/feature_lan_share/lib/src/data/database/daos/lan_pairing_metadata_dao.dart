part of '../lan_share_database.dart';

/// 对端非敏感配对展示元数据 DAO。
@DriftAccessor(tables: [LanPairingMetadata])
class LanPairingMetadataDao extends DatabaseAccessor<LanShareDatabase>
    with _$LanPairingMetadataDaoMixin {
  LanPairingMetadataDao(super.db);

  /// 读取全部对端元数据。
  Future<List<LanPairingMetadataData>> getAll() =>
      select(lanPairingMetadata).get();

  /// 写入一个不含密钥的对端快照。
  Future<void> upsert(LanPairingMetadataCompanion entry) async {
    await into(
      lanPairingMetadata,
    ).insert(entry, mode: InsertMode.insertOrReplace);
  }

  /// 删除一个对端快照。
  Future<int> deleteDevice(String deviceId) => (delete(
    lanPairingMetadata,
  )..where((t) => t.deviceId.equals(deviceId))).go();

  /// 清空全部对端元数据。
  Future<int> clearAll() => delete(lanPairingMetadata).go();
}
