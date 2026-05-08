import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'data_protection_service.dart';

class StorageService extends ChangeNotifier {
  static const _connectionsKey = 'ssh_connections';
  static const _powerGuideSeenKey = 'power_guide_seen';
  static const _restorableTmuxSessionsKey = 'restorable_tmux_sessions';
  static const _terminalHistoryRecordsKey = 'terminal_history_records';
  static const _aiBaseUrlKey = 'ai_base_url';
  static const _aiModelKey = 'ai_model';
  static const _aiApiKeyKey = 'ai_api_key';
  static const _aiChatsKey = 'ai_chats';

  SharedPreferences? _prefs;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final DataProtectionService _dataProtection = DataProtectionService.instance;

  List<ConnectionConfig> _connections = [];
  bool _initialized = false;
  bool _powerGuideSeen = false;

  List<ConnectionConfig> get connections => List.unmodifiable(_connections);
  bool get initialized => _initialized;
  bool get powerGuideSeen => _powerGuideSeen;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
      _powerGuideSeen = _prefs?.getBool(_powerGuideSeenKey) ?? false;
      await _loadConnections();
    } catch (e) {
      debugPrint('Failed to initialize storage service: $e');
      AppLogService.instance
          .error('Failed to initialize storage service', error: e);
      _connections = [];
      _powerGuideSeen = false;
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  Future<void> _loadConnections() async {
    final jsonStr = await _readProtectedPref(_connectionsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      _connections = [];
      return;
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      _connections = list
          .map(
              (item) => ConnectionConfig.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Failed to load SSH connections: $e');
      AppLogService.instance.error('Failed to load SSH connections', error: e);
      _connections = [];
    }
  }

  Future<void> _saveConnections() async {
    if (!_initialized || _prefs == null) return;
    final jsonStr =
        jsonEncode(_connections.map((item) => item.toJson()).toList());
    await _writeProtectedPref(_connectionsKey, jsonStr);
  }

  Future<void> addConnection(ConnectionConfig config) async {
    _ensureInitialized();

    final exists = _connections.any((item) => item.id == config.id);
    if (exists) {
      throw StateError('Connection id already exists: ${config.id}');
    }

    _connections.add(config);
    await _saveSecrets(config);
    await _saveConnections();
    notifyListeners();
  }

  Future<void> updateConnection(ConnectionConfig config) async {
    _ensureInitialized();

    final index = _connections.indexWhere((item) => item.id == config.id);
    if (index == -1) {
      throw StateError('Connection does not exist: ${config.id}');
    }

    _connections[index] = config;
    await _saveSecrets(config);
    await _saveConnections();
    if (config.launchMode != TerminalLaunchMode.tmux) {
      await removeRestorableTmuxSessionsForConnection(config.id);
    }
    notifyListeners();
  }

  Future<void> deleteConnection(String id) async {
    if (!_initialized) return;

    _connections.removeWhere((item) => item.id == id);
    await _secureStorage.delete(key: 'pwd_$id');
    await _secureStorage.delete(key: 'key_$id');
    await removeRestorableTmuxSessionsForConnection(id);
    await _saveConnections();
    notifyListeners();
  }

  ConnectionConfig? getConnection(String id) {
    try {
      return _connections.firstWhere((item) => item.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<String?> getPassword(String id) async {
    if (!_initialized) return null;
    return _secureStorage.read(key: 'pwd_$id');
  }

  Future<String?> getPrivateKey(String id) async {
    if (!_initialized) return null;
    return _secureStorage.read(key: 'key_$id');
  }

  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    final baseUrl = _prefs?.getString(_aiBaseUrlKey)?.trim();
    final model = _prefs?.getString(_aiModelKey)?.trim();
    final apiKey = await _secureStorage.read(key: _aiApiKeyKey);
    return AiConnectionSettings(
      baseUrl:
          baseUrl?.isNotEmpty == true ? baseUrl! : 'https://api.deepseek.com',
      model: model?.isNotEmpty == true ? model! : 'deepseek-v4-flash',
      hasApiKey: apiKey?.isNotEmpty == true,
    );
  }

  Future<String?> getAiApiKey() async {
    if (!_initialized) return null;
    return _secureStorage.read(key: _aiApiKeyKey);
  }

  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    if (!_initialized || _prefs == null) return;
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = model.trim();
    await _prefs!.setString(_aiBaseUrlKey, normalizedBaseUrl);
    await _prefs!.setString(_aiModelKey, normalizedModel);
    var apiKeyUpdated = false;
    if (apiKey != null) {
      final trimmed = apiKey.trim();
      if (trimmed.isNotEmpty) {
        await _secureStorage.write(key: _aiApiKeyKey, value: trimmed);
        apiKeyUpdated = true;
      }
    }
    AppLogService.instance.info(
      'LLM settings saved',
      details:
          'baseUrl=$normalizedBaseUrl model=$normalizedModel apiKeyUpdated=$apiKeyUpdated',
    );
    notifyListeners();
  }

  Future<List<AiChatRecord>> loadAiChats() async {
    if (!_initialized || _prefs == null) return [];
    final jsonStr = await _readProtectedPref(_aiChatsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final chats = list
          .map((item) => AiChatRecord.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return chats;
    } catch (e) {
      debugPrint('Failed to load AI chats: $e');
      AppLogService.instance.error('Failed to load AI chats', error: e);
      return [];
    }
  }

  Future<void> saveAiChat(AiChatRecord chat) async {
    if (!_initialized || _prefs == null) return;
    final chats = await loadAiChats();
    chats.removeWhere((item) => item.id == chat.id);
    chats.insert(0, chat);
    await _saveAiChats(chats.take(80).toList());
    notifyListeners();
  }

  Future<void> deleteAiChat(String id) async {
    if (!_initialized || _prefs == null) return;
    final chats = await loadAiChats();
    chats.removeWhere((item) => item.id == id);
    await _saveAiChats(chats);
    notifyListeners();
  }

  Future<void> markPowerGuideSeen() async {
    if (!_initialized) return;
    _powerGuideSeen = true;
    await _prefs?.setBool(_powerGuideSeenKey, true);
    notifyListeners();
  }

  Future<List<RestorableTmuxSession>> loadRestorableTmuxSessions() async {
    if (!_initialized || _prefs == null) return [];
    final jsonStr = await _readProtectedPref(_restorableTmuxSessionsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((item) =>
              RestorableTmuxSession.fromJson(item as Map<String, dynamic>))
          .where((item) => getConnection(item.connectionId) != null)
          .toList();
    } catch (e) {
      debugPrint('Failed to load restorable tmux sessions: $e');
      AppLogService.instance.error(
        'Failed to load restorable tmux sessions',
        error: e,
      );
      return [];
    }
  }

  Future<void> saveRestorableTmuxSession(RestorableTmuxSession session) async {
    if (!_initialized || _prefs == null) return;
    final sessions = await loadRestorableTmuxSessions();
    sessions.removeWhere((item) => item.sessionId == session.sessionId);
    sessions.add(session);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> removeRestorableTmuxSession(String sessionId) async {
    if (!_initialized || _prefs == null) return;
    final sessions = await loadRestorableTmuxSessions();
    sessions.removeWhere((item) => item.sessionId == sessionId);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> removeRestorableTmuxSessionsForConnection(
    String connectionId,
  ) async {
    if (!_initialized || _prefs == null) return;
    final sessions = await loadRestorableTmuxSessions();
    sessions.removeWhere((item) => item.connectionId == connectionId);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> clearRestorableTmuxSessions() async {
    if (!_initialized || _prefs == null) return;
    await _prefs!.remove(_restorableTmuxSessionsKey);
  }

  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() async {
    if (!_initialized || _prefs == null) return [];
    final jsonStr = await _readProtectedPref(_terminalHistoryRecordsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final records = list
          .map((item) =>
              TerminalHistoryRecord.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return records;
    } catch (e) {
      debugPrint('Failed to load terminal history records: $e');
      AppLogService.instance.error(
        'Failed to load terminal history records',
        error: e,
      );
      return [];
    }
  }

  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) async {
    if (!_initialized || _prefs == null) return;
    final records = await loadTerminalHistoryRecords();
    records.removeWhere((item) => item.sessionId == record.sessionId);
    records.insert(0, record);
    await _saveTerminalHistoryRecords(records.take(200).toList());
    notifyListeners();
  }

  Future<void> removeTerminalHistoryRecord(String sessionId) async {
    if (!_initialized || _prefs == null) return;
    final records = await loadTerminalHistoryRecords();
    records.removeWhere((item) => item.sessionId == sessionId);
    await _saveTerminalHistoryRecords(records);
    notifyListeners();
  }

  Future<void> _saveRestorableTmuxSessions(
    List<RestorableTmuxSession> sessions,
  ) async {
    final jsonStr = jsonEncode(sessions.map((item) => item.toJson()).toList());
    await _writeProtectedPref(_restorableTmuxSessionsKey, jsonStr);
  }

  Future<void> _saveTerminalHistoryRecords(
    List<TerminalHistoryRecord> records,
  ) async {
    final jsonStr = jsonEncode(records.map((item) => item.toJson()).toList());
    await _writeProtectedPref(_terminalHistoryRecordsKey, jsonStr);
  }

  Future<void> _saveAiChats(List<AiChatRecord> chats) async {
    final jsonStr = jsonEncode(chats.map((item) => item.toJson()).toList());
    await _writeProtectedPref(_aiChatsKey, jsonStr);
  }

  Future<String?> _readProtectedPref(String key) async {
    final value = _prefs?.getString(key);
    if (value == null || value.isEmpty) return value;
    if (!_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.decryptString(value);
  }

  Future<void> _writeProtectedPref(String key, String value) async {
    final encrypted = await _dataProtection.encryptString(value);
    await _prefs!.setString(key, encrypted);
  }

  Future<void> _saveSecrets(ConnectionConfig config) async {
    if (config.password != null && config.password!.isNotEmpty) {
      await _secureStorage.write(
          key: 'pwd_${config.id}', value: config.password);
    } else {
      await _secureStorage.delete(key: 'pwd_${config.id}');
    }

    if (config.privateKey != null && config.privateKey!.isNotEmpty) {
      await _secureStorage.write(
          key: 'key_${config.id}', value: config.privateKey);
    } else {
      await _secureStorage.delete(key: 'key_${config.id}');
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('Storage service is not initialized yet.');
    }
  }
}

class AiConnectionSettings {
  final String baseUrl;
  final String model;
  final bool hasApiKey;

  const AiConnectionSettings({
    required this.baseUrl,
    required this.model,
    required this.hasApiKey,
  });
}

class AiChatRecord {
  final String id;
  final String title;
  final String model;
  final List<AiChatMessageRecord> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AiChatRecord({
    required this.id,
    required this.title,
    required this.model,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  AiChatRecord copyWith({
    String? title,
    String? model,
    List<AiChatMessageRecord>? messages,
    DateTime? updatedAt,
  }) {
    return AiChatRecord(
      id: id,
      title: title ?? this.title,
      model: model ?? this.model,
      messages: messages ?? this.messages,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'model': model,
      'messages': messages.map((item) => item.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory AiChatRecord.fromJson(Map<String, dynamic> json) {
    return AiChatRecord(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'New chat',
      model: json['model'] as String? ?? 'deepseek-v4-flash',
      messages: ((json['messages'] as List<dynamic>?) ?? const [])
          .map((item) =>
              AiChatMessageRecord.fromJson(item as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class AiChatMessageRecord {
  final String role;
  final String text;
  final DateTime createdAt;

  const AiChatMessageRecord({
    required this.role,
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AiChatMessageRecord.fromJson(Map<String, dynamic> json) {
    return AiChatMessageRecord(
      role: json['role'] as String? ?? 'assistant',
      text: json['text'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class RestorableTmuxSession {
  final String sessionId;
  final String connectionId;
  final String displayName;
  final String tmuxSessionName;
  final double fontSize;
  final DateTime updatedAt;

  const RestorableTmuxSession({
    required this.sessionId,
    required this.connectionId,
    required this.displayName,
    required this.tmuxSessionName,
    required this.fontSize,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'connectionId': connectionId,
      'displayName': displayName,
      'tmuxSessionName': tmuxSessionName,
      'fontSize': fontSize,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory RestorableTmuxSession.fromJson(Map<String, dynamic> json) {
    return RestorableTmuxSession(
      sessionId: json['sessionId'] as String,
      connectionId: json['connectionId'] as String,
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String? ?? 'ssh_mobile',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class TerminalHistoryRecord {
  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String? tmuxSessionName;
  final String state;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TerminalHistoryRecord({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    required this.tmuxSessionName,
    required this.state,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  String? get tmuxKillCommand {
    final name = tmuxSessionName;
    if (name == null || name.isEmpty) return null;
    return "tmux kill-session -t ${_shellQuote(name)}";
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'connectionId': connectionId,
      'connectionName': connectionName,
      'displayName': displayName,
      'tmuxSessionName': tmuxSessionName,
      'state': state,
      'errorMessage': errorMessage,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory TerminalHistoryRecord.fromJson(Map<String, dynamic> json) {
    return TerminalHistoryRecord(
      sessionId: json['sessionId'] as String,
      connectionId: json['connectionId'] as String? ?? '',
      connectionName: json['connectionName'] as String? ?? 'SSH',
      displayName: json['displayName'] as String? ?? 'SSH',
      tmuxSessionName: json['tmuxSessionName'] as String?,
      state: json['state'] as String? ?? 'disconnected',
      errorMessage: json['errorMessage'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}
