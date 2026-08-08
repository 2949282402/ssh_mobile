part of '../storage_service.dart';

extension DriftOps on StorageService {
  void _requireDriftStorage(bool featureActive, String featureName) {
    if (!_driftReady || !featureActive || _database == null) {
      throw StateError('$featureName storage is unavailable.');
    }
  }

  Future<void> _initializeDriftStorage() async {
    try {
      if (_disposed) return;
      final database = appDatabase;
      await database.customSelect('SELECT 1').getSingle();
      if (_disposed) return;
      _driftReady = true;

      _driftAiChatsActive = true;
      _driftAgentMetricsActive = true;
      _driftAgentTraceActive = true;
      _driftTerminalHistoryActive = true;
      _driftPlaybooksActive = true;
      _driftSftpHistoryActive = true;

      try {
        await AppLogService.instance.setDatabase(database);
      } catch (e, stackTrace) {
        // Storage remains usable when another live StorageService owns the
        // process-wide log sink (for example during an import handoff).
        AppLogService.instance.warning(
          'Drift storage initialized without attaching the app log sink',
          details: '$e\n$stackTrace',
        );
      }
    } catch (e, stackTrace) {
      _driftReady = false;
      _driftAiChatsActive = false;
      _driftAgentMetricsActive = false;
      _driftAgentTraceActive = false;
      _driftTerminalHistoryActive = false;
      _driftPlaybooksActive = false;
      _driftSftpHistoryActive = false;
      AppLogService.instance.error(
        'Failed to initialize Drift storage',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (!_driftInitCompleter.isCompleted) {
        _driftInitCompleter.complete();
      }
    }
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

  Future<String> _decryptDriftText(String value) async {
    if (value.isEmpty) return value;
    if (!_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.decryptString(value);
  }
}
