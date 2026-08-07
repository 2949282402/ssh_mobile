part of '../terminal_database.dart';

/// Terminal 历史数据访问对象；限制记录数避免元数据无限增长。
@DriftAccessor(tables: [TerminalHistory])
class TerminalHistoryDao extends DatabaseAccessor<TerminalDatabase>
    with _$TerminalHistoryDaoMixin {
  /// 创建 DAO。
  TerminalHistoryDao(super.db);

  /// 按更新时间倒序读取记录。
  Future<List<TerminalHistoryData>> loadRecords() {
    return (select(terminalHistory)..orderBy([
          (row) =>
              OrderingTerm(expression: row.updatedAt, mode: OrderingMode.desc),
        ]))
        .get();
  }

  /// 写入一条记录并清理最旧数据。
  Future<void> saveRecord(TerminalHistoryCompanion record) async {
    await into(terminalHistory).insertOnConflictUpdate(record);
    final ids =
        await (selectOnly(terminalHistory)
              ..addColumns([terminalHistory.sessionId])
              ..orderBy([
                OrderingTerm(
                  expression: terminalHistory.updatedAt,
                  mode: OrderingMode.desc,
                ),
              ]))
            .map((row) => row.read(terminalHistory.sessionId))
            .get()
            .then(
              (values) => values.whereType<String>().toList(growable: false),
            );
    final staleIds = ids.skip(200).toList(growable: false);
    if (staleIds.isNotEmpty) {
      await (delete(
        terminalHistory,
      )..where((row) => row.sessionId.isIn(staleIds))).go();
    }
  }

  /// 迁移兼容用的全量替换操作。
  Future<void> replaceAll(List<TerminalHistoryCompanion> records) async {
    await transaction(() async {
      await delete(terminalHistory).go();
      final retained = records.take(200).toList(growable: false);
      if (retained.isNotEmpty) {
        await batch((batch) => batch.insertAll(terminalHistory, retained));
      }
    });
  }

  /// 删除指定会话记录。
  Future<void> removeRecord(String sessionId) {
    return (delete(
      terminalHistory,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  }
}
