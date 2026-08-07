// Terminal 历史 Repository 的 Drift 实现。
//
// Repository 只持有 Module 注入的数据库引用，不拥有数据库生命周期；写入
// 使用 DAO 的有界策略，保证旧数据不会无限增长。

import 'package:drift/drift.dart';

import '../../domain/terminal_models.dart';
import '../database/terminal_database.dart';
import '../../domain/terminal_ports.dart';

/// 基于 terminal.db 的历史记录 Repository。
final class DriftTerminalHistoryRepository
    implements TerminalHistoryRepository {
  /// 创建 Repository。
  DriftTerminalHistoryRepository(this.database);

  /// 由 TerminalModule 持有的数据库引用。
  final TerminalDatabase database;

  @override
  Future<List<TerminalHistoryRecord>> loadRecords() async {
    final rows = await database.terminalHistoryDao.loadRecords();
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<void> saveRecord(TerminalHistoryRecord record) {
    return database.terminalHistoryDao.saveRecord(_toCompanion(record));
  }

  @override
  Future<void> removeRecord(String sessionId) {
    return database.terminalHistoryDao.removeRecord(sessionId);
  }

  @override
  Future<void> replaceAll(Iterable<TerminalHistoryRecord> records) {
    final ordered = records.toList()..sort(_compareUpdatedAt);
    return database.terminalHistoryDao.replaceAll(
      ordered.map(_toCompanion).toList(growable: false),
    );
  }

  TerminalHistoryCompanion _toCompanion(TerminalHistoryRecord record) {
    return TerminalHistoryCompanion(
      sessionId: Value(record.sessionId),
      connectionId: Value(record.connectionId),
      connectionName: Value(record.connectionName),
      displayName: Value(record.displayName),
      tmuxSessionName: Value(record.tmuxSessionName),
      state: Value(record.state),
      errorMessage: Value(record.errorMessage),
      createdAt: Value(record.createdAt.toUtc().millisecondsSinceEpoch),
      updatedAt: Value(record.updatedAt.toUtc().millisecondsSinceEpoch),
    );
  }

  TerminalHistoryRecord _fromRow(TerminalHistoryData row) {
    return TerminalHistoryRecord(
      sessionId: row.sessionId,
      connectionId: row.connectionId,
      connectionName: row.connectionName,
      displayName: row.displayName,
      tmuxSessionName: row.tmuxSessionName,
      state: row.state,
      errorMessage: row.errorMessage,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.createdAt,
        isUtc: true,
      ).toLocal(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row.updatedAt,
        isUtc: true,
      ).toLocal(),
    );
  }

  int _compareUpdatedAt(TerminalHistoryRecord a, TerminalHistoryRecord b) {
    return b.updatedAt.compareTo(a.updatedAt);
  }
}
