part of '../app_database.dart';

@DriftAccessor(tables: [LanTransferRecords])
class LanHistoryDao extends DatabaseAccessor<AppDatabase>
    with _$LanHistoryDaoMixin {
  LanHistoryDao(super.db);

  Future<List<LanTransferRecord>> getAllRecords() {
    return (select(lanTransferRecords)..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
        .get();
  }

  Stream<List<LanTransferRecord>> watchAllRecords() {
    return (select(lanTransferRecords)..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
        .watch();
  }

  Future<LanTransferRecord?> getRecord(String id) {
    return (select(
      lanTransferRecords,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<int> insertRecord(LanTransferRecordsCompanion record) {
    return into(
      lanTransferRecords,
    ).insert(record, mode: InsertMode.insertOrReplace);
  }

  Future<bool> updateSensitiveFields(
    String id, {
    required Value<String?> textContent,
    required Value<String?> manifestJson,
    required Value<String?> sftpRemotePath,
  }) async {
    final count =
        await (update(lanTransferRecords)..where((t) => t.id.equals(id))).write(
          LanTransferRecordsCompanion(
            textContent: textContent,
            manifestJson: manifestJson,
            sftpRemotePath: sftpRemotePath,
          ),
        );
    return count > 0;
  }

  Future<bool> updateRecordStatus(
    String id,
    String status, {
    int? bytesTransferred,
    bool? isRecalled,
    String? localPath,
  }) async {
    final count =
        await (update(lanTransferRecords)..where((t) => t.id.equals(id))).write(
          LanTransferRecordsCompanion(
            status: Value(status),
            bytesTransferred: bytesTransferred != null
                ? Value(bytesTransferred)
                : const Value.absent(),
            isRecalled: isRecalled != null
                ? Value(isRecalled)
                : const Value.absent(),
            localPath: localPath != null
                ? Value(localPath)
                : const Value.absent(),
          ),
        );
    return count > 0;
  }

  Future<int> deleteRecord(String id) {
    return (delete(lanTransferRecords)..where((t) => t.id.equals(id))).go();
  }

  Future<int> deleteExpiredRecords(int expiredBeforeTimestamp) {
    return (delete(
          lanTransferRecords,
        )..where((t) => t.createdAt.isSmallerThanValue(expiredBeforeTimestamp)))
        .go();
  }

  Future<int> clearAllRecords() {
    return delete(lanTransferRecords).go();
  }
}
