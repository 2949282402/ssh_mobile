part of '../app_database.dart';

@DriftAccessor(tables: [TerminalHistoryRecords])
class TerminalHistoryDao extends DatabaseAccessor<AppDatabase>
    with _$TerminalHistoryDaoMixin {
  TerminalHistoryDao(super.db);

  Future<List<TerminalHistoryRecord>> loadRecords() {
    return (select(terminalHistoryRecords)..orderBy([
          (row) =>
              OrderingTerm(expression: row.updatedAt, mode: OrderingMode.desc),
        ]))
        .get();
  }

  Future<void> saveRecord(TerminalHistoryRecordsCompanion record) async {
    await into(terminalHistoryRecords).insertOnConflictUpdate(record);
    final orderedIds =
        await (selectOnly(terminalHistoryRecords)
              ..addColumns([terminalHistoryRecords.sessionId])
              ..orderBy([
                OrderingTerm(
                  expression: terminalHistoryRecords.updatedAt,
                  mode: OrderingMode.desc,
                ),
              ]))
            .map((row) => row.read(terminalHistoryRecords.sessionId))
            .get()
            .then((ids) => ids.whereType<String>().toList(growable: false));
    final staleIds = orderedIds.skip(200).toList(growable: false);
    if (staleIds.isNotEmpty) {
      await (delete(
        terminalHistoryRecords,
      )..where((row) => row.sessionId.isIn(staleIds))).go();
    }
  }

  Future<void> replaceAllRecords(
    List<TerminalHistoryRecordsCompanion> records,
  ) async {
    await transaction(() async {
      await delete(terminalHistoryRecords).go();
      final retained = records.take(200).toList(growable: false);
      if (retained.isNotEmpty) {
        await batch(
          (batch) => batch.insertAll(terminalHistoryRecords, retained),
        );
      }
    });
  }

  Future<void> removeRecord(String sessionId) async {
    await (delete(
      terminalHistoryRecords,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  }
}
