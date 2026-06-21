part of '../storage_service.dart';

const int _driftSensitiveReencryptBatchSize = 50;

extension DriftOps on StorageService {
  Future<void> _initializeDriftStorage() async {
    try {
      final database = _providedDatabase ?? db.AppDatabase();
      _database = database;
      _ownsDatabase = _providedDatabase == null;
      await ensureAppDatabaseOpen(database);
      _driftReady = true;

      _driftAiChatsActive = await _migrateAiChatsToDrift();
      _driftAgentMetricsActive = await _migrateAgentMetricsToDrift();
      _driftTerminalHistoryActive = await _migrateTerminalHistoryToDrift();
      _driftPlaybooksActive = await _migratePlaybooksToDrift();
      await _reencryptDriftSensitiveFieldsIfNeeded();
      _driftSftpHistoryActive = true;
    } catch (e, stackTrace) {
      _driftReady = false;
      _driftAiChatsActive = false;
      _driftAgentMetricsActive = false;
      _driftTerminalHistoryActive = false;
      _driftPlaybooksActive = false;
      _driftSftpHistoryActive = false;
      AppLogService.instance.error(
        'Failed to initialize Drift storage',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _migrateAiChatsToDrift() async {
    final database = _database;
    if (!_driftReady || database == null) return false;
    if (await database.migrationMetaDao
        .isComplete(StorageService._driftAiChatsMigratedKey)) {
      return true;
    }
    try {
      final jsonStr = await _readProtectedPref(StorageService._aiChatsKey);
      final chats = _decodeLegacyRecordList(jsonStr, AiChatRecord.fromJson)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _replaceDriftAiChats(chats);
      await database.migrationMetaDao
          .markComplete(StorageService._driftAiChatsMigratedKey);
      return true;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to migrate AI chats to Drift',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _migrateAgentMetricsToDrift() async {
    final database = _database;
    if (!_driftReady || database == null) return false;
    if (await database.migrationMetaDao
        .isComplete(StorageService._driftAgentMetricsMigratedKey)) {
      return true;
    }
    try {
      final jsonStr =
          await _readProtectedPref(StorageService._agentRunMetricsKey);
      final metrics = _decodeLegacyRecordList(jsonStr, AgentRunMetrics.fromJson)
        ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
      await _replaceDriftAgentRunMetrics(metrics);
      await database.migrationMetaDao
          .markComplete(StorageService._driftAgentMetricsMigratedKey);
      return true;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to migrate agent metrics to Drift',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _migrateTerminalHistoryToDrift() async {
    final database = _database;
    if (!_driftReady || database == null) return false;
    if (await database.migrationMetaDao
        .isComplete(StorageService._driftTerminalHistoryMigratedKey)) {
      return true;
    }
    try {
      final jsonStr = await _readProtectedPref(
        StorageService._terminalHistoryRecordsKey,
      );
      final records =
          _decodeLegacyRecordList(jsonStr, TerminalHistoryRecord.fromJson)
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _replaceDriftTerminalHistoryRecords(records);
      await database.migrationMetaDao
          .markComplete(StorageService._driftTerminalHistoryMigratedKey);
      return true;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to migrate terminal history to Drift',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _migratePlaybooksToDrift() async {
    final database = _database;
    if (!_driftReady || database == null) return false;
    if (await database.migrationMetaDao
        .isComplete(StorageService._driftPlaybooksMigratedKey)) {
      return true;
    }
    try {
      final jsonStr = await _readProtectedPref(StorageService._playbooksKey);
      final playbooks = _decodeLegacyRecordList(jsonStr, Playbook.fromJson)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _replaceDriftPlaybooks(playbooks);
      await database.migrationMetaDao
          .markComplete(StorageService._driftPlaybooksMigratedKey);
      return true;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to migrate playbooks to Drift',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _reencryptDriftSensitiveFieldsIfNeeded() async {
    final database = _database;
    if (!_driftReady || database == null) return;
    if (await database.migrationMetaDao.isComplete(
      StorageService._driftSensitiveFieldsEncryptedKey,
    )) {
      return;
    }

    try {
      final aiMessageRows =
          await _reencryptAiChatMessageRowsInBatches(database);
      final playbookRows = await _reencryptPlaybookRowsInBatches(database);
      await database.migrationMetaDao.markComplete(
        StorageService._driftSensitiveFieldsEncryptedKey,
      );
      AppLogService.instance.info(
        'Drift sensitive fields re-encrypted',
        details: 'aiMessages=$aiMessageRows playbooks=$playbookRows',
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to re-encrypt Drift sensitive fields',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<int> _reencryptAiChatMessageRowsInBatches(
    db.AppDatabase database,
  ) async {
    final rows = await database.aiChatDao.loadAllMessagesForReencryption();
    var updated = 0;
    for (var start = 0;
        start < rows.length;
        start += _driftSensitiveReencryptBatchSize) {
      final end = (start + _driftSensitiveReencryptBatchSize)
          .clamp(0, rows.length)
          .toInt();
      final batch = rows.sublist(start, end);
      updated += await database.transaction(
        () => _reencryptAiChatMessageBatch(database, batch),
      );
    }
    return updated;
  }

  Future<int> _reencryptAiChatMessageBatch(
    db.AppDatabase database,
    List<db.AiChatMessage> rows,
  ) async {
    var updated = 0;
    for (final row in rows) {
      final encryptedText = await _encryptIfPlaintext(row.textContent);
      final encryptedContext = row.contextText == null
          ? null
          : await _encryptIfPlaintext(row.contextText!);
      final encryptedAttachments =
          await _encryptIfPlaintext(row.attachmentsJson);
      final encryptedTraces = await _encryptIfPlaintext(row.tracesJson);
      final encryptedTodoSteps = await _encryptIfPlaintext(row.todoStepsJson);

      final changed = encryptedText != row.textContent ||
          encryptedContext != row.contextText ||
          encryptedAttachments != row.attachmentsJson ||
          encryptedTraces != row.tracesJson ||
          encryptedTodoSteps != row.todoStepsJson;
      if (!changed) continue;

      await database.aiChatDao.updateMessageSensitiveFields(
        id: row.id,
        textContent: encryptedText,
        contextText: encryptedContext,
        attachmentsJson: encryptedAttachments,
        tracesJson: encryptedTraces,
        todoStepsJson: encryptedTodoSteps,
      );
      updated++;
    }
    return updated;
  }

  Future<int> _reencryptPlaybookRowsInBatches(
    db.AppDatabase database,
  ) async {
    final rows = await database.playbookDao.loadAllPlaybooksForReencryption();
    var updated = 0;
    for (var start = 0;
        start < rows.length;
        start += _driftSensitiveReencryptBatchSize) {
      final end = (start + _driftSensitiveReencryptBatchSize)
          .clamp(0, rows.length)
          .toInt();
      final batch = rows.sublist(start, end);
      updated += await database.transaction(
        () => _reencryptPlaybookBatch(database, batch),
      );
    }
    return updated;
  }

  Future<int> _reencryptPlaybookBatch(
    db.AppDatabase database,
    List<db.Playbook> rows,
  ) async {
    var updated = 0;
    for (final row in rows) {
      final encryptedContent = await _encryptIfPlaintext(row.contentJson);
      if (encryptedContent == row.contentJson) continue;

      await database.playbookDao.updatePlaybookContentJson(
        id: row.id,
        contentJson: encryptedContent,
      );
      updated++;
    }
    return updated;
  }

  List<T> _decodeLegacyRecordList<T>(
    String? jsonStr,
    T Function(Map<String, dynamic>) decode,
  ) {
    if (jsonStr == null || jsonStr.isEmpty) return <T>[];
    final decoded = jsonDecode(jsonStr);
    if (decoded is! List) return <T>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(decode)
        .toList(growable: false);
  }

  int _toDbMillis(DateTime dateTime) => dateTime.toUtc().millisecondsSinceEpoch;

  DateTime _fromDbMillis(int millis) {
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
  }

  String _encodeJsonList(Iterable<Map<String, dynamic>> items) {
    return jsonEncode(items.toList(growable: false));
  }

  List<T> _decodeJsonList<T>(
    String jsonText,
    T Function(Map<String, dynamic>) decode,
  ) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! List) return <T>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(decode)
        .toList(growable: false);
  }

  Future<String> _encryptDriftText(String value) async {
    if (value.isEmpty) return value;
    if (_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.encryptString(value);
  }

  Future<String> _encryptIfPlaintext(String value) async {
    if (value.isEmpty) return value;
    if (_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.encryptString(value);
  }

  Future<String> _decryptDriftText(String value) async {
    if (value.isEmpty) return value;
    if (!_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.decryptString(value);
  }
}
