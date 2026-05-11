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
  static const _aiContextWindowKey = 'ai_context_window';
  static const _aiTimeoutSecondsKey = 'ai_timeout_seconds';
  static const _aiApiKeyKey = 'ai_api_key';
  static const _aiChatsKey = 'ai_chats';
  static const _aiSkillsKey = 'ai_skills';

  SharedPreferences? _prefs;
  // macOS builds run in the app sandbox. The plugin's default Data Protection
  // Keychain mode requires extra Keychain entitlements and can fail with
  // errSecMissingEntitlement (-34018), so use the regular Keychain there.
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  final DataProtectionService _dataProtection = DataProtectionService.instance;

  List<ConnectionConfig> _connections = [];
  List<ConnectionConfig> _connectionsView = const [];
  bool _initialized = false;
  bool _powerGuideSeen = false;

  List<ConnectionConfig> get connections => _connectionsView;
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
      _refreshConnectionsView();
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
      _refreshConnectionsView();
      return;
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      _connections = list
          .map(
              (item) => ConnectionConfig.fromJson(item as Map<String, dynamic>))
          .toList();
      _refreshConnectionsView();
    } catch (e) {
      debugPrint('Failed to load SSH connections: $e');
      AppLogService.instance.error('Failed to load SSH connections', error: e);
      _connections = [];
      _refreshConnectionsView();
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
    _refreshConnectionsView();
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
    _refreshConnectionsView();
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
    _refreshConnectionsView();
    await _secureStorage.delete(key: 'pwd_$id');
    await _secureStorage.delete(key: 'key_$id');
    await removeRestorableTmuxSessionsForConnection(id);
    await _saveConnections();
    notifyListeners();
  }

  void _refreshConnectionsView() {
    _connectionsView = List.unmodifiable(_connections);
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
    final contextWindow = _prefs?.getInt(_aiContextWindowKey);
    final apiKey = await getAiApiKey();
    return AiConnectionSettings(
      baseUrl:
          baseUrl?.isNotEmpty == true ? baseUrl! : 'https://api.deepseek.com',
      model: model?.isNotEmpty == true ? model! : 'deepseek-v4-flash',
      contextWindowTokens: AiContextWindowSize.normalize(contextWindow),
      timeoutSeconds: await getAiRequestTimeoutSeconds(),
      hasApiKey: apiKey?.isNotEmpty == true,
    );
  }

  Future<int> getAiRequestTimeoutSeconds() async {
    return AiRequestTimeout.normalize(_prefs?.getInt(_aiTimeoutSecondsKey));
  }

  Future<String?> getAiApiKey() async {
    if (!_initialized) return null;
    final value = await _secureStorage.read(key: _aiApiKeyKey);
    final normalized = _normalizeAiApiKey(value);
    if (value != null && value.isNotEmpty && normalized == null) {
      await _secureStorage.delete(key: _aiApiKeyKey);
      AppLogService.instance.warning(
        'Invalid LLM API key cleared',
        details: 'Stored key contained characters that cannot be used safely.',
      );
    }
    return normalized;
  }

  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    int? contextWindowTokens,
    int? timeoutSeconds,
    String? apiKey,
  }) async {
    if (!_initialized || _prefs == null) return;
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = model.trim();
    await _prefs!.setString(_aiBaseUrlKey, normalizedBaseUrl);
    await _prefs!.setString(_aiModelKey, normalizedModel);
    await _prefs!.setInt(
      _aiContextWindowKey,
      AiContextWindowSize.normalize(contextWindowTokens),
    );
    await _prefs!.setInt(
      _aiTimeoutSecondsKey,
      AiRequestTimeout.normalize(timeoutSeconds),
    );
    var apiKeyUpdated = false;
    if (apiKey != null) {
      final normalizedApiKey = _normalizeAiApiKey(apiKey);
      if (apiKey.trim().isNotEmpty && normalizedApiKey == null) {
        AppLogService.instance.warning(
          'LLM settings rejected invalid API key',
          details:
              'baseUrl=$normalizedBaseUrl model=$normalizedModel inputLength=${apiKey.length}',
        );
        throw const FormatException('Invalid API key format.');
      }
      if (normalizedApiKey != null) {
        await _secureStorage.write(key: _aiApiKeyKey, value: normalizedApiKey);
        apiKeyUpdated = true;
      }
    }
    AppLogService.instance.info(
      'LLM settings saved',
      details:
          'baseUrl=$normalizedBaseUrl model=$normalizedModel contextWindow=${AiContextWindowSize.normalize(contextWindowTokens)} timeoutSeconds=${AiRequestTimeout.normalize(timeoutSeconds)} apiKeyUpdated=$apiKeyUpdated',
    );
    // AI settings are loaded on demand by the chat page. Avoid notifying the
    // whole storage tree while the settings dialog is being dismissed; doing so
    // can rebuild provider dependents during route teardown on Android.
  }

  String? _normalizeAiApiKey(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.contains(RegExp(r'[\r\n\t]'))) return null;
    if (trimmed.contains('package:flutter/') ||
        trimmed.contains('Failed assertion') ||
        trimmed.contains('docs.flutter.dev/testing/errors')) {
      return null;
    }
    if (trimmed.length > 4096) return null;
    return trimmed;
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

  Future<List<AiSkillRecord>> loadAiSkills() async {
    if (!_initialized || _prefs == null) return [];
    final jsonStr = await _readProtectedPref(_aiSkillsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((item) => AiSkillRecord.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (e) {
      debugPrint('Failed to load AI skills: $e');
      AppLogService.instance.error('Failed to load AI skills', error: e);
      return [];
    }
  }

  Future<void> saveAiSkill(AiSkillRecord skill) async {
    if (!_initialized || _prefs == null) return;
    final skills = await loadAiSkills();
    skills.removeWhere((item) => item.id == skill.id);
    skills.insert(0, skill);
    await _saveAiSkills(skills);
    notifyListeners();
  }

  Future<void> deleteAiSkill(String id) async {
    if (!_initialized || _prefs == null) return;
    final skills = await loadAiSkills();
    skills.removeWhere((item) => item.id == id);
    await _saveAiSkills(skills);
    notifyListeners();
  }

  Future<String> exportAppDataJson() async {
    if (!_initialized || _prefs == null) {
      throw StateError('Storage service is not initialized yet.');
    }
    final connectionPayloads = <Map<String, dynamic>>[];
    for (final connection in _connections) {
      // Backup files are portable user data, not secret vaults. Keep credential
      // fields present but empty so imports know the user must reconfigure them.
      connectionPayloads.add({
        ...connection.toJson(),
        'password': '',
        'privateKey': '',
      });
    }
    final settings = await loadAiConnectionSettings();
    final payload = {
      'format': 'ssh_mobile_backup',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'connections': connectionPayloads,
      'restorableTmuxSessions': (await loadRestorableTmuxSessions())
          .map((item) => item.toJson())
          .toList(),
      'terminalHistoryRecords': (await loadTerminalHistoryRecords())
          .map((item) => item.toJson())
          .toList(),
      'aiSettings': {
        'baseUrl': settings.baseUrl,
        'model': settings.model,
        'contextWindowTokens': settings.contextWindowTokens,
        'timeoutSeconds': settings.timeoutSeconds,
        'apiKey': '',
      },
      'aiChats': (await loadAiChats()).map((item) => item.toJson()).toList(),
      'aiSkills': (await loadAiSkills()).map((item) => item.toJson()).toList(),
      'powerGuideSeen': _powerGuideSeen,
    };
    AppLogService.instance.info(
      'App data exported',
      details:
          'connections=${connectionPayloads.length} chats=${(payload['aiChats'] as List).length} skills=${(payload['aiSkills'] as List).length} secrets=omitted',
    );
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> importAppDataJson(String jsonText) async {
    if (!_initialized || _prefs == null) {
      throw StateError('Storage service is not initialized yet.');
    }
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'ssh_mobile_backup') {
      throw StateError('Unsupported backup file.');
    }

    final importedConnections = <ConnectionConfig>[];
    for (final item in (decoded['connections'] as List<dynamic>? ?? const [])) {
      if (item is! Map<String, dynamic>) continue;
      final config = ConnectionConfig.fromJson(item);
      importedConnections.add(config);
      await _secureStorage.delete(key: 'pwd_${config.id}');
      await _secureStorage.delete(key: 'key_${config.id}');
    }

    for (final old in _connections) {
      if (importedConnections.any((item) => item.id == old.id)) continue;
      await _secureStorage.delete(key: 'pwd_${old.id}');
      await _secureStorage.delete(key: 'key_${old.id}');
    }
    _connections = importedConnections;
    _refreshConnectionsView();
    await _saveConnections();

    final aiSettings = decoded['aiSettings'];
    if (aiSettings is Map<String, dynamic>) {
      final importedApiKey = aiSettings['apiKey'] as String?;
      if (importedApiKey == null || importedApiKey.trim().isEmpty) {
        await _secureStorage.delete(key: _aiApiKeyKey);
      }
      await saveAiConnectionSettings(
        baseUrl: aiSettings['baseUrl'] as String? ?? 'https://api.deepseek.com',
        model: aiSettings['model'] as String? ?? 'deepseek-v4-flash',
        contextWindowTokens:
            (aiSettings['contextWindowTokens'] as num?)?.toInt(),
        timeoutSeconds: (aiSettings['timeoutSeconds'] as num?)?.toInt(),
        apiKey: importedApiKey,
      );
    }

    await _saveRestorableTmuxSessions(
      ((decoded['restorableTmuxSessions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RestorableTmuxSession.fromJson)
          .toList(),
    );
    await _saveTerminalHistoryRecords(
      ((decoded['terminalHistoryRecords'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TerminalHistoryRecord.fromJson)
          .toList(),
    );
    await _saveAiChats(
      ((decoded['aiChats'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiChatRecord.fromJson)
          .toList(),
    );
    await _saveAiSkills(
      ((decoded['aiSkills'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiSkillRecord.fromJson)
          .toList(),
    );
    _powerGuideSeen = decoded['powerGuideSeen'] as bool? ?? _powerGuideSeen;
    await _prefs?.setBool(_powerGuideSeenKey, _powerGuideSeen);
    AppLogService.instance.info(
      'App data imported',
      details:
          'connections=${_connections.length} chats=${((decoded['aiChats'] as List<dynamic>?) ?? const []).length} skills=${((decoded['aiSkills'] as List<dynamic>?) ?? const []).length}',
    );
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

  Future<void> _saveAiSkills(List<AiSkillRecord> skills) async {
    final jsonStr = jsonEncode(skills.map((item) => item.toJson()).toList());
    await _writeProtectedPref(_aiSkillsKey, jsonStr);
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
  final int contextWindowTokens;
  final int timeoutSeconds;
  final bool hasApiKey;

  const AiConnectionSettings({
    required this.baseUrl,
    required this.model,
    required this.contextWindowTokens,
    required this.timeoutSeconds,
    required this.hasApiKey,
  });
}

class AiRequestTimeout {
  static const int k30 = 30;
  static const int k60 = 60;
  static const int k90 = 90;
  static const int k120 = 120;
  static const int k180 = 180;
  static const int k300 = 300;
  static const int defaultSeconds = k60;
  static const List<int> values = [k30, k60, k90, k120, k180, k300];

  static int normalize(int? value) {
    return values.contains(value) ? value! : defaultSeconds;
  }

  static String label(int value) {
    return '${normalize(value)}s';
  }
}

class AiContextWindowSize {
  static const int k259 = 259000;
  static const int k512 = 512000;
  static const int k1m = 1000000;
  static const List<int> values = [k259, k512, k1m];

  static int normalize(int? value) {
    if (value == k512 || value == k1m) return value!;
    return k259;
  }

  static String label(int value) {
    switch (normalize(value)) {
      case k512:
        return '512K';
      case k1m:
        return '1M';
      default:
        return '259K';
    }
  }
}

class AiSkillRecord {
  final String id;
  final String name;
  final String description;
  final String content;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AiSkillRecord({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  AiSkillRecord copyWith({
    String? name,
    String? description,
    String? content,
    bool? enabled,
    DateTime? updatedAt,
  }) {
    return AiSkillRecord(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'content': content,
      'enabled': enabled,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory AiSkillRecord.fromJson(Map<String, dynamic> json) {
    return AiSkillRecord(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Skill',
      description: json['description'] as String? ?? '',
      content: json['content'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
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
  final String? contextText;
  final List<AiMessageTrace> traces;
  final DateTime createdAt;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? elapsedMs;
  final bool? tokenUsageEstimated;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;

  const AiChatMessageRecord({
    required this.role,
    required this.text,
    this.contextText,
    this.traces = const [],
    required this.createdAt,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.elapsedMs,
    this.tokenUsageEstimated,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens,
    this.reasoningTokens,
  });

  AiChatMessageRecord copyWith({
    String? role,
    String? text,
    String? contextText,
    List<AiMessageTrace>? traces,
    DateTime? createdAt,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
    int? elapsedMs,
    bool? tokenUsageEstimated,
    int? promptCacheHitTokens,
    int? promptCacheMissTokens,
    int? reasoningTokens,
  }) {
    return AiChatMessageRecord(
      role: role ?? this.role,
      text: text ?? this.text,
      contextText: contextText ?? this.contextText,
      traces: traces ?? this.traces,
      createdAt: createdAt ?? this.createdAt,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      totalTokens: totalTokens ?? this.totalTokens,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      tokenUsageEstimated: tokenUsageEstimated ?? this.tokenUsageEstimated,
      promptCacheHitTokens: promptCacheHitTokens ?? this.promptCacheHitTokens,
      promptCacheMissTokens:
          promptCacheMissTokens ?? this.promptCacheMissTokens,
      reasoningTokens: reasoningTokens ?? this.reasoningTokens,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'text': text,
      if (contextText != null) 'contextText': contextText,
      if (traces.isNotEmpty)
        'traces': traces.map((trace) => trace.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (totalTokens != null) 'totalTokens': totalTokens,
      if (elapsedMs != null) 'elapsedMs': elapsedMs,
      if (tokenUsageEstimated != null)
        'tokenUsageEstimated': tokenUsageEstimated,
      if (promptCacheHitTokens != null)
        'promptCacheHitTokens': promptCacheHitTokens,
      if (promptCacheMissTokens != null)
        'promptCacheMissTokens': promptCacheMissTokens,
      if (reasoningTokens != null) 'reasoningTokens': reasoningTokens,
    };
  }

  factory AiChatMessageRecord.fromJson(Map<String, dynamic> json) {
    return AiChatMessageRecord(
      role: json['role'] as String? ?? 'assistant',
      text: json['text'] as String? ?? '',
      contextText: json['contextText'] as String?,
      traces: ((json['traces'] as List<dynamic>?) ?? const [])
          .map((item) => AiMessageTrace.fromJson(item as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      promptTokens: json['promptTokens'] as int?,
      completionTokens: json['completionTokens'] as int?,
      totalTokens: json['totalTokens'] as int?,
      elapsedMs: json['elapsedMs'] as int?,
      tokenUsageEstimated: json['tokenUsageEstimated'] as bool?,
      promptCacheHitTokens: json['promptCacheHitTokens'] as int?,
      promptCacheMissTokens: json['promptCacheMissTokens'] as int?,
      reasoningTokens: json['reasoningTokens'] as int?,
    );
  }
}

class AiMessageTrace {
  final String kind;
  final String title;
  final String content;
  final DateTime createdAt;

  const AiMessageTrace({
    required this.kind,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'kind': kind,
      'title': title,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AiMessageTrace.fromJson(Map<String, dynamic> json) {
    return AiMessageTrace(
      kind: json['kind'] as String? ?? 'info',
      title: json['title'] as String? ?? 'Details',
      content: json['content'] as String? ?? '',
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
