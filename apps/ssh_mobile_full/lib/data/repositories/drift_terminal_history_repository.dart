part of '../../services/storage_service.dart';

extension DriftTerminalHistoryRepositoryOps on StorageService {
  Future<List<TerminalHistoryRecord>> _loadDriftTerminalHistoryRecords() async {
    final database = _database;
    if (!_driftTerminalHistoryActive || database == null) return const [];
    final rows = await database.terminalHistoryDao.loadRecords();
    final records = rows.map(_terminalHistoryFromDrift).toList(growable: false);
    return _terminalHistoryRecordsCache = List.unmodifiable(records);
  }

  Future<void> _saveDriftTerminalHistoryRecord(
    TerminalHistoryRecord record,
  ) async {
    final database = _database;
    if (!_driftTerminalHistoryActive || database == null) return;
    await database.terminalHistoryDao.saveRecord(
      _terminalHistoryToCompanion(record),
    );
    final current =
        _terminalHistoryRecordsCache ?? const <TerminalHistoryRecord>[];
    final next = <TerminalHistoryRecord>[
      record,
      ...current.where((item) => item.sessionId != record.sessionId),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (next.length > 200) {
      next.removeRange(200, next.length);
    }
    _terminalHistoryRecordsCache = List.unmodifiable(next);
  }

  Future<void> _removeDriftTerminalHistoryRecord(String sessionId) async {
    final database = _database;
    if (!_driftTerminalHistoryActive || database == null) return;
    await database.terminalHistoryDao.removeRecord(sessionId);
    final cached = _terminalHistoryRecordsCache;
    if (cached != null) {
      _terminalHistoryRecordsCache = List.unmodifiable(
        cached
            .where((item) => item.sessionId != sessionId)
            .toList(growable: false),
      );
    }
  }

  Future<void> _replaceDriftTerminalHistoryRecords(
    List<TerminalHistoryRecord> records,
  ) async {
    final database = _database;
    if (!_driftReady || database == null) return;
    final ordered = [...records]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await database.terminalHistoryDao.replaceAllRecords(
      ordered.map(_terminalHistoryToCompanion).toList(growable: false),
    );
    _terminalHistoryRecordsCache = List.unmodifiable(ordered.take(200));
  }

  db.TerminalHistoryRecordsCompanion _terminalHistoryToCompanion(
    TerminalHistoryRecord record,
  ) {
    return db.TerminalHistoryRecordsCompanion(
      sessionId: drift.Value(record.sessionId),
      connectionId: drift.Value(record.connectionId),
      connectionName: drift.Value(record.connectionName),
      displayName: drift.Value(record.displayName),
      tmuxSessionName: drift.Value(record.tmuxSessionName),
      state: drift.Value(record.state),
      errorMessage: drift.Value(record.errorMessage),
      createdAt: drift.Value(_toDbMillis(record.createdAt)),
      updatedAt: drift.Value(_toDbMillis(record.updatedAt)),
    );
  }

  TerminalHistoryRecord _terminalHistoryFromDrift(
    db.TerminalHistoryRecord row,
  ) {
    return TerminalHistoryRecord(
      sessionId: row.sessionId,
      connectionId: row.connectionId,
      connectionName: row.connectionName,
      displayName: row.displayName,
      tmuxSessionName: row.tmuxSessionName,
      state: row.state,
      errorMessage: row.errorMessage,
      createdAt: _fromDbMillis(row.createdAt),
      updatedAt: _fromDbMillis(row.updatedAt),
    );
  }
}
