import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'data_protection_service.dart';

/// 中央持久化服务。管理应用的所有数据持久化，采用三层存储策略：
///
/// | 数据类型            | 存储位置                              | 加密方式        |
/// |---------------------|---------------------------------------|-----------------|
/// | SSH 密码、私钥、API | FlutterSecureStorage (平台 Keychain)  | 平台原生加密     |
/// | 连接配置、聊天记录   | SharedPreferences + AES-256-GCM       | DataProtection   |
/// | 主题、语言、字体     | SharedPreferences 明文                 | 无（不含敏感信息）|
///
/// 高频写操作（AI 聊天、tmux 会话、终端历史）使用 700ms 防抖批量写入，
/// App 进入后台时调用 flushPendingWrites() 确保数据落盘。
class StorageService extends ChangeNotifier {
  static const _connectionsKey = 'ssh_connections';
  static const _powerGuideSeenKey = 'power_guide_seen';
  static const _restorableTmuxSessionsKey = 'restorable_tmux_sessions';
  static const _terminalHistoryRecordsKey = 'terminal_history_records';
  static const _aiBaseUrlKey = 'ai_base_url';
  static const _aiModelKey = 'ai_model';
  static const _aiContextWindowKey = 'ai_context_window';
  static const _aiTimeoutSecondsKey = 'ai_timeout_seconds';
  static const _aiDeepSeekThinkingEnabledKey = 'ai_deepseek_thinking_enabled';
  static const _aiDeepSeekReasoningEffortKey = 'ai_deepseek_reasoning_effort';
  static const _aiWebSearchEnabledKey = 'ai_web_search_enabled';
  static const _aiWebSearchProviderKey = 'ai_web_search_provider';
  static const _aiWebSearchBaseUrlKey = 'ai_web_search_base_url';
  static const _aiWebSearchMaxResultsKey = 'ai_web_search_max_results';
  static const _aiApiKeyKey = 'ai_api_key';
  static const _aiChatsKey = 'ai_chats';
  static const _aiSkillsKey = 'ai_skills';
  static const _secretCacheEnabledKey = 'secret_cache_enabled';
  static const _secretCacheTtlSecondsKey = 'secret_cache_ttl_seconds';
  static const _defaultSecretCacheTtl = Duration(minutes: 15);
  static const _protectedPrefWriteDebounce = Duration(milliseconds: 700); // 防抖窗口
  static const _passwordSecretKeyPrefix = 'pwd_';
  static const _privateKeySecretKeyPrefix = 'key_';
  static const _memoryAiApiKeyCacheKey = 'ai_api_key_cached';
  static const _memorySecretTtlOptionsMinutes = [1, 5, 15, 30, 60];

  SharedPreferences? _prefs;
  // macOS builds run in the app sandbox. The plugin's default Data Protection
  // Keychain mode requires extra Keychain entitlements and can fail with
  // errSecMissingEntitlement (-34018), so use the regular Keychain there.
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  final DataProtectionService _dataProtection = DataProtectionService.instance;
  // 防抖写入队列：key → 待写入值，700ms 内多次修改只写最后一次
  final Map<String, _PendingProtectedPrefWrite> _pendingProtectedPrefWrites =
      {};

  List<ConnectionConfig> _connections = [];
  List<ConnectionConfig> _connectionsView = const []; // 不可变视图暴露给外部
  List<AiChatRecord>? _aiChatsCache;
  List<AiSkillRecord>? _aiSkillsCache;
  List<RestorableTmuxSession>? _restorableTmuxSessionsCache;
  List<TerminalHistoryRecord>? _terminalHistoryRecordsCache;
  bool _initialized = false;
  bool _powerGuideSeen = false;
  bool _secretCacheEnabled = true;
  Duration _secretCacheTtl = const Duration(minutes: 15);
  // 内存缓存：密码/私钥/API Key 的 in-memory TTL 缓存，减少 Keychain 访问
  final Map<String, _MemorySecret> _secretCache = {};

  List<ConnectionConfig> get connections => _connectionsView;
  bool get isSecretCacheEnabled => _secretCacheEnabled;
  Duration get secretCacheTtl => _secretCacheTtl;
  int get secretCacheTtlMinutes => _secretCacheTtl.inMinutes;
  List<int> get secretCacheTtlOptionsMinutes =>
      List.unmodifiable(_memorySecretTtlOptionsMinutes);
  bool get initialized => _initialized;
  bool get powerGuideSeen => _powerGuideSeen;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
      _powerGuideSeen = _prefs?.getBool(_powerGuideSeenKey) ?? false;
      await _loadSecretCacheSettings();
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

  /// 从 SharedPreferences 读取密钥缓存开关和 TTL
  Future<void> _loadSecretCacheSettings() async {
    if (_prefs == null) return;
    _secretCacheEnabled = _prefs!.getBool(_secretCacheEnabledKey) ?? true;

    final ttlSeconds = _prefs!.getInt(_secretCacheTtlSecondsKey);
    if (ttlSeconds != null && ttlSeconds > 0) {
      _secretCacheTtl = _normalizeSecretCacheTtl(Duration(seconds: ttlSeconds));
    } else {
      _secretCacheTtl = _defaultSecretCacheTtl;
    }
  }

  /// 将用户输入的 TTL 规整到预设选项中最接近的大于等于值
  Duration _normalizeSecretCacheTtl(Duration value) {
    final requested = value.inMinutes.clamp(1, 120);
    final normalized = _memorySecretTtlOptionsMinutes.firstWhere(
      (option) => option >= requested,
      orElse: () => _memorySecretTtlOptionsMinutes.last,
    );
    return Duration(minutes: normalized);
  }

  Future<void> setSecretCacheEnabled(bool enabled) async {
    if (!_initialized || _prefs == null) return;
    if (_secretCacheEnabled == enabled) return;
    _secretCacheEnabled = enabled;
    if (!enabled) {
      clearSecretCache();
    }
    await _prefs!.setBool(_secretCacheEnabledKey, enabled);
    notifyListeners();
  }

  Future<void> setSecretCacheTtl(Duration ttl) async {
    if (!_initialized || _prefs == null) return;
    final normalized = _normalizeSecretCacheTtl(ttl);
    if (_secretCacheTtl == normalized) return;
    _secretCacheTtl = normalized;
    await _prefs!.setInt(_secretCacheTtlSecondsKey, normalized.inSeconds);
    notifyListeners();
  }

  /// 清除所有内存中缓存的秘密（密码/私钥/API Key）
  void clearSecretCache() {
    _secretCache.remove(_memoryAiApiKeyCacheKey);
    for (final key in _secretCache.keys.toList()) {
      if (key.startsWith(_passwordSecretKeyPrefix) ||
          key.startsWith(_privateKeySecretKeyPrefix)) {
        _secretCache.remove(key);
      }
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
    _clearSecretCacheForConnection(id);
    await _secureStorage.delete(key: 'pwd_$id');
    await _secureStorage.delete(key: 'key_$id');
    await removeRestorableTmuxSessionsForConnection(id);
    await _saveConnections();
    notifyListeners();
  }

  Future<void> deleteConnections(List<String> ids) async {
    if (!_initialized) return;
    for (final id in ids) {
      _connections.removeWhere((item) => item.id == id);
      _clearSecretCacheForConnection(id);
      await _secureStorage.delete(key: 'pwd_$id');
      await _secureStorage.delete(key: 'key_$id');
      await removeRestorableTmuxSessionsForConnection(id);
    }
    _refreshConnectionsView();
    await _saveConnections();
    notifyListeners();
  }

  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    if (!_initialized) return;
    if (newIndex > oldIndex) newIndex--;
    final item = _connections.removeAt(oldIndex);
    _connections.insert(newIndex, item);
    _refreshConnectionsView();
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
    return _readSecretWithCache(_cacheKeyPassword(id));
  }

  Future<String?> getPrivateKey(String id) async {
    if (!_initialized) return null;
    return _readSecretWithCache(_cacheKeyPrivateKey(id));
  }

  /// 加载 AI 连接设置（baseUrl、model、timeout 等），
  /// 各字段为空时返回合理的默认值。
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    final baseUrl = _prefs?.getString(_aiBaseUrlKey)?.trim();
    final model = _prefs?.getString(_aiModelKey)?.trim();
    final contextWindow = _prefs?.getInt(_aiContextWindowKey);
    final thinkingEnabled =
        _prefs?.getBool(_aiDeepSeekThinkingEnabledKey) ?? true;
    final reasoningEffort = DeepSeekReasoningEffort.normalize(
      _prefs?.getString(_aiDeepSeekReasoningEffortKey),
    );
    final webSearchProvider = AiWebSearchProvider.normalize(
      _prefs?.getString(_aiWebSearchProviderKey),
    );
    final webSearchBaseUrl = _prefs?.getString(_aiWebSearchBaseUrlKey)?.trim();
    final apiKey = await getAiApiKey();
    return AiConnectionSettings(
      baseUrl:
          baseUrl?.isNotEmpty == true ? baseUrl! : 'https://api.deepseek.com',
      model: model?.isNotEmpty == true ? model! : 'deepseek-v4-flash',
      contextWindowTokens: AiContextWindowSize.normalize(contextWindow),
      timeoutSeconds: await getAiRequestTimeoutSeconds(),
      deepSeekThinkingEnabled: thinkingEnabled,
      deepSeekReasoningEffort: reasoningEffort,
      webSearchEnabled: _prefs?.getBool(_aiWebSearchEnabledKey) ?? false,
      webSearchProvider: webSearchProvider,
      webSearchBaseUrl: webSearchBaseUrl ?? '',
      webSearchMaxResults: AiWebSearchMaxResults.normalize(
        _prefs?.getInt(_aiWebSearchMaxResultsKey),
      ),
      hasApiKey: apiKey?.isNotEmpty == true,
    );
  }

  Future<int> getAiRequestTimeoutSeconds() async {
    return AiRequestTimeout.normalize(_prefs?.getInt(_aiTimeoutSecondsKey));
  }

  Future<String?> getAiApiKey() async {
    if (!_initialized) return null;
    final cache = _readCachedSecretEntry(_memoryAiApiKeyCacheKey);
    if (cache != null) return cache.value;

    final value = await _secureStorage.read(key: _aiApiKeyKey);
    final normalized = _normalizeAiApiKey(value);
    if (value != null && value.isNotEmpty && normalized == null) {
      await _secureStorage.delete(key: _aiApiKeyKey);
      _secretCache.remove(_memoryAiApiKeyCacheKey);
      AppLogService.instance.warning(
        'Invalid LLM API key cleared',
        details: 'Stored key contained characters that cannot be used safely.',
      );
      return null;
    }
    if (_secretCacheEnabled) {
      _secretCache[_memoryAiApiKeyCacheKey] = _MemorySecret(
        value: normalized,
        loadedAt: DateTime.now(),
      );
    }
    return normalized;
  }

  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    int? contextWindowTokens,
    int? timeoutSeconds,
    bool? deepSeekThinkingEnabled,
    String? deepSeekReasoningEffort,
    bool? webSearchEnabled,
    String? webSearchProvider,
    String? webSearchBaseUrl,
    int? webSearchMaxResults,
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
    await _prefs!.setBool(
      _aiDeepSeekThinkingEnabledKey,
      deepSeekThinkingEnabled ??
          (_prefs!.getBool(_aiDeepSeekThinkingEnabledKey) ?? true),
    );
    await _prefs!.setString(
      _aiDeepSeekReasoningEffortKey,
      DeepSeekReasoningEffort.normalize(
        deepSeekReasoningEffort ??
            _prefs!.getString(_aiDeepSeekReasoningEffortKey),
      ),
    );
    await _prefs!.setBool(
      _aiWebSearchEnabledKey,
      webSearchEnabled ?? (_prefs!.getBool(_aiWebSearchEnabledKey) ?? false),
    );
    await _prefs!.setString(
      _aiWebSearchProviderKey,
      AiWebSearchProvider.normalize(
        webSearchProvider ?? _prefs!.getString(_aiWebSearchProviderKey),
      ),
    );
    await _prefs!.setString(
      _aiWebSearchBaseUrlKey,
      webSearchBaseUrl?.trim() ??
          _prefs!.getString(_aiWebSearchBaseUrlKey)?.trim() ??
          '',
    );
    await _prefs!.setInt(
      _aiWebSearchMaxResultsKey,
      AiWebSearchMaxResults.normalize(
        webSearchMaxResults ?? _prefs!.getInt(_aiWebSearchMaxResultsKey),
      ),
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
        if (_secretCacheEnabled) {
          _secretCache[_memoryAiApiKeyCacheKey] = _MemorySecret(
            value: normalizedApiKey,
            loadedAt: DateTime.now(),
          );
        }
        apiKeyUpdated = true;
      } else {
        _secretCache.remove(_memoryAiApiKeyCacheKey);
      }
    }
    AppLogService.instance.info(
      'LLM settings saved',
      details:
          'baseUrl=$normalizedBaseUrl model=$normalizedModel contextWindow=${AiContextWindowSize.normalize(contextWindowTokens)} timeoutSeconds=${AiRequestTimeout.normalize(timeoutSeconds)} deepSeekThinking=${deepSeekThinkingEnabled ?? (_prefs!.getBool(_aiDeepSeekThinkingEnabledKey) ?? true)} deepSeekEffort=${DeepSeekReasoningEffort.normalize(deepSeekReasoningEffort ?? _prefs!.getString(_aiDeepSeekReasoningEffortKey))} webSearch=${webSearchEnabled ?? (_prefs!.getBool(_aiWebSearchEnabledKey) ?? false)} webSearchProvider=${AiWebSearchProvider.normalize(webSearchProvider ?? _prefs!.getString(_aiWebSearchProviderKey))} apiKeyUpdated=$apiKeyUpdated',
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
    final cached = _aiChatsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(_aiChatsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _aiChatsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final chats = list
          .map((item) => AiChatRecord.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return _aiChatsCache = List.unmodifiable(chats);
    } catch (e) {
      debugPrint('Failed to load AI chats: $e');
      AppLogService.instance.error('Failed to load AI chats', error: e);
      return _aiChatsCache = const [];
    }
  }

  Future<void> saveAiChat(AiChatRecord chat) async {
    if (!_initialized || _prefs == null) return;
    final chats = [...await loadAiChats()];
    chats.removeWhere((item) => item.id == chat.id);
    chats.insert(0, chat);
    await _saveAiChats(chats.take(80).toList());
    notifyListeners();
  }

  Future<void> deleteAiChat(String id) async {
    if (!_initialized || _prefs == null) return;
    final chats = [...await loadAiChats()];
    chats.removeWhere((item) => item.id == id);
    await _saveAiChats(chats);
    notifyListeners();
  }

  Future<List<AiSkillRecord>> loadAiSkills() async {
    if (!_initialized || _prefs == null) return [];
    final cached = _aiSkillsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(_aiSkillsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _aiSkillsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final skills = list
          .map((item) => AiSkillRecord.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return _aiSkillsCache = List.unmodifiable(skills);
    } catch (e) {
      debugPrint('Failed to load AI skills: $e');
      AppLogService.instance.error('Failed to load AI skills', error: e);
      return _aiSkillsCache = const [];
    }
  }

  Future<void> saveAiSkill(AiSkillRecord skill) async {
    if (!_initialized || _prefs == null) return;
    final skills = [...await loadAiSkills()];
    skills.removeWhere((item) => item.id == skill.id);
    skills.insert(0, skill);
    await _saveAiSkills(skills);
    notifyListeners();
  }

  Future<void> deleteAiSkill(String id) async {
    if (!_initialized || _prefs == null) return;
    final skills = [...await loadAiSkills()];
    skills.removeWhere((item) => item.id == id);
    await _saveAiSkills(skills);
    notifyListeners();
  }

  /// 导出所有用户数据为 JSON 格式。
  /// 注意：密码/私钥/API Key 置空，不包含在导出中。
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
        'deepSeekThinkingEnabled': settings.deepSeekThinkingEnabled,
        'deepSeekReasoningEffort': settings.deepSeekReasoningEffort,
        'webSearchEnabled': settings.webSearchEnabled,
        'webSearchProvider': settings.webSearchProvider,
        'webSearchBaseUrl': settings.webSearchBaseUrl,
        'webSearchMaxResults': settings.webSearchMaxResults,
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

  /// 从 JSON 备份导入所有用户数据。
  /// 格式校验：必须包含 'ssh_mobile_backup' 标记。
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
      _clearSecretCacheForConnection(config.id);
      await _secureStorage.delete(key: 'pwd_${config.id}');
      await _secureStorage.delete(key: 'key_${config.id}');
    }

    for (final old in _connections) {
      if (importedConnections.any((item) => item.id == old.id)) continue;
      _clearSecretCacheForConnection(old.id);
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
        deepSeekThinkingEnabled: aiSettings['deepSeekThinkingEnabled'] as bool?,
        deepSeekReasoningEffort:
            aiSettings['deepSeekReasoningEffort'] as String?,
        webSearchEnabled: aiSettings['webSearchEnabled'] as bool?,
        webSearchProvider: aiSettings['webSearchProvider'] as String?,
        webSearchBaseUrl: aiSettings['webSearchBaseUrl'] as String?,
        webSearchMaxResults:
            (aiSettings['webSearchMaxResults'] as num?)?.toInt(),
        apiKey: importedApiKey,
      );
    }

    await _saveRestorableTmuxSessions(
      ((decoded['restorableTmuxSessions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RestorableTmuxSession.fromJson)
          .toList(),
      immediate: true,
    );
    await _saveTerminalHistoryRecords(
      ((decoded['terminalHistoryRecords'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TerminalHistoryRecord.fromJson)
          .toList(),
      immediate: true,
    );
    await _saveAiChats(
      ((decoded['aiChats'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiChatRecord.fromJson)
          .toList(),
      immediate: true,
    );
    await _saveAiSkills(
      ((decoded['aiSkills'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AiSkillRecord.fromJson)
          .toList(),
      immediate: true,
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
    final cached = _restorableTmuxSessionsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(_restorableTmuxSessionsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _restorableTmuxSessionsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final sessions = list
          .map((item) =>
              RestorableTmuxSession.fromJson(item as Map<String, dynamic>))
          .where((item) => getConnection(item.connectionId) != null)
          .toList();
      return _restorableTmuxSessionsCache = List.unmodifiable(sessions);
    } catch (e) {
      debugPrint('Failed to load restorable tmux sessions: $e');
      AppLogService.instance.error(
        'Failed to load restorable tmux sessions',
        error: e,
      );
      return _restorableTmuxSessionsCache = const [];
    }
  }

  Future<void> saveRestorableTmuxSession(RestorableTmuxSession session) async {
    if (!_initialized || _prefs == null) return;
    final sessions = [...await loadRestorableTmuxSessions()];
    sessions.removeWhere((item) => item.sessionId == session.sessionId);
    sessions.add(session);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> removeRestorableTmuxSession(String sessionId) async {
    if (!_initialized || _prefs == null) return;
    final sessions = [...await loadRestorableTmuxSessions()];
    sessions.removeWhere((item) => item.sessionId == sessionId);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> removeRestorableTmuxSessionsForConnection(
    String connectionId,
  ) async {
    if (!_initialized || _prefs == null) return;
    final sessions = [...await loadRestorableTmuxSessions()];
    sessions.removeWhere((item) => item.connectionId == connectionId);
    await _saveRestorableTmuxSessions(sessions);
  }

  Future<void> clearRestorableTmuxSessions() async {
    if (!_initialized || _prefs == null) return;
    _restorableTmuxSessionsCache = const [];
    _cancelPendingProtectedPrefWrite(_restorableTmuxSessionsKey);
    await _prefs!.remove(_restorableTmuxSessionsKey);
  }

  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() async {
    if (!_initialized || _prefs == null) return [];
    final cached = _terminalHistoryRecordsCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(_terminalHistoryRecordsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _terminalHistoryRecordsCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final records = list
          .map((item) =>
              TerminalHistoryRecord.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return _terminalHistoryRecordsCache = List.unmodifiable(records);
    } catch (e) {
      debugPrint('Failed to load terminal history records: $e');
      AppLogService.instance.error(
        'Failed to load terminal history records',
        error: e,
      );
      return _terminalHistoryRecordsCache = const [];
    }
  }

  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) async {
    if (!_initialized || _prefs == null) return;
    final records = [...await loadTerminalHistoryRecords()];
    records.removeWhere((item) => item.sessionId == record.sessionId);
    records.insert(0, record);
    await _saveTerminalHistoryRecords(records.take(200).toList());
    notifyListeners();
  }

  Future<void> removeTerminalHistoryRecord(String sessionId) async {
    if (!_initialized || _prefs == null) return;
    final records = [...await loadTerminalHistoryRecords()];
    records.removeWhere((item) => item.sessionId == sessionId);
    await _saveTerminalHistoryRecords(records);
    notifyListeners();
  }

  Future<void> _saveRestorableTmuxSessions(
    List<RestorableTmuxSession> sessions, {
    bool immediate = false,
  }) async {
    _restorableTmuxSessionsCache = List.unmodifiable(sessions);
    final jsonStr = jsonEncode(sessions.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      _restorableTmuxSessionsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<void> _saveTerminalHistoryRecords(
    List<TerminalHistoryRecord> records, {
    bool immediate = false,
  }) async {
    final sorted = [...records]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _terminalHistoryRecordsCache = List.unmodifiable(sorted);
    final jsonStr = jsonEncode(sorted.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      _terminalHistoryRecordsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<void> _saveAiChats(
    List<AiChatRecord> chats, {
    bool immediate = false,
  }) async {
    final sorted = [...chats]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _aiChatsCache = List.unmodifiable(sorted);
    final jsonStr = jsonEncode(sorted.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      _aiChatsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<void> _saveAiSkills(
    List<AiSkillRecord> skills, {
    bool immediate = false,
  }) async {
    final sorted = [...skills]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _aiSkillsCache = List.unmodifiable(sorted);
    final jsonStr = jsonEncode(sorted.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      _aiSkillsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  String _cacheKeyPassword(String connectionId) =>
      '$_passwordSecretKeyPrefix$connectionId';

  String _cacheKeyPrivateKey(String connectionId) =>
      '$_privateKeySecretKeyPrefix$connectionId';

  void _cacheConnectionSecretsFromConfig(ConnectionConfig config) {
    if (!_secretCacheEnabled) return;
    _secretCache[_cacheKeyPassword(config.id)] = _MemorySecret(
      value: config.password,
      loadedAt: DateTime.now(),
    );
    _secretCache[_cacheKeyPrivateKey(config.id)] = _MemorySecret(
      value: config.privateKey,
      loadedAt: DateTime.now(),
    );
  }

  void _clearSecretCacheForConnection(String connectionId) {
    _secretCache.remove(_cacheKeyPassword(connectionId));
    _secretCache.remove(_cacheKeyPrivateKey(connectionId));
  }

  _MemorySecret? _readCachedSecretEntry(String cacheKey) {
    if (!_secretCacheEnabled) return null;
    final cached = _secretCache[cacheKey];
    if (cached == null) return null;
    if (DateTime.now().difference(cached.loadedAt) > _secretCacheTtl) {
      _secretCache.remove(cacheKey);
      return null;
    }
    return cached;
  }

  Future<String?> _readSecretWithCache(String key) async {
    if (!_secretCacheEnabled) return _secureStorage.read(key: key);
    final cached = _readCachedSecretEntry(key);
    if (cached != null) {
      return cached.value;
    }
    final value = await _secureStorage.read(key: key);
    _secretCache[key] = _MemorySecret(value: value, loadedAt: DateTime.now());
    return value;
  }

  /// 加密读取：从 SharedPreferences 读取后，如果已加密则自动解密
  Future<String?> _readProtectedPref(String key) async {
    final value = _prefs?.getString(key);
    if (value == null || value.isEmpty) return value;
    if (!_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.decryptString(value);
  }

  /// 加密写入：先加密再写入 SharedPreferences
  Future<void> _writeProtectedPref(String key, String value) async {
    final encrypted = await _dataProtection.encryptString(value);
    await _prefs!.setString(key, encrypted);
  }

  /// 带防抖的加密写入。
  /// immediate=true：跳过防抖立即写入（用于导出/导入等紧急场景）。
  /// immediate=false：700ms 内多次调用只执行最后一次写入。
  Future<void> _writeProtectedPrefBuffered(
    String key,
    String value, {
    required bool immediate,
  }) {
    if (immediate) {
      final pending = _pendingProtectedPrefWrites[key];
      pending?.timer?.cancel();
      if (pending == null) {
        return _writeProtectedPref(key, value);
      }
      pending.value = value;
      pending.generation++;
      return _flushProtectedPrefWrite(key);
    }

    final pending = _pendingProtectedPrefWrites.putIfAbsent(
      key,
      () => _PendingProtectedPrefWrite(value),
    );
    pending.value = value;
    pending.generation++;
    pending.timer?.cancel();
    pending.timer = Timer(_protectedPrefWriteDebounce, () {
      unawaited(_flushProtectedPrefWrite(key));
    });
    return Future.value();
  }

  Future<void> flushPendingWrites() async {
    final keys = _pendingProtectedPrefWrites.keys.toList(growable: false);
    await Future.wait(keys.map(_flushProtectedPrefWrite));
  }

  Future<void> _flushProtectedPrefWrite(String key) {
    final pending = _pendingProtectedPrefWrites[key];
    if (pending == null) return Future.value();
    pending.timer?.cancel();
    pending.timer = null;
    final generation = pending.generation;
    final value = pending.value;
    final previous = pending.writeChain;
    final next = previous.catchError((_) {}).then((_) async {
      await _writeProtectedPref(key, value);
    });
    pending.writeChain = next.whenComplete(() {
      final current = _pendingProtectedPrefWrites[key];
      if (!identical(current, pending)) return;
      if (current!.generation == generation && current.timer == null) {
        _pendingProtectedPrefWrites.remove(key);
      }
    });
    return pending.writeChain;
  }

  void _cancelPendingProtectedPrefWrite(String key) {
    final pending = _pendingProtectedPrefWrites.remove(key);
    pending?.timer?.cancel();
  }

  Future<void> _saveSecrets(ConnectionConfig config) async {
    _cacheConnectionSecretsFromConfig(config);
    final passwordKey = _cacheKeyPassword(config.id);
    final privateKeyKey = _cacheKeyPrivateKey(config.id);
    if (config.password != null && config.password!.isNotEmpty) {
      await _secureStorage.write(key: passwordKey, value: config.password);
    } else {
      await _secureStorage.delete(key: passwordKey);
    }

    if (config.privateKey != null && config.privateKey!.isNotEmpty) {
      await _secureStorage.write(key: privateKeyKey, value: config.privateKey);
    } else {
      await _secureStorage.delete(key: privateKeyKey);
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('Storage service is not initialized yet.');
    }
  }

  @override
  void dispose() {
    for (final pending in _pendingProtectedPrefWrites.values) {
      pending.timer?.cancel();
    }
    unawaited(flushPendingWrites());
    super.dispose();
  }
}

/// 带生成计数的延迟写入请求，用于防抖机制。
/// generation 避免竞争条件：如果某 key 在防抖期内被更新多次，
/// 前序的 flush 执行完毕后检测 generation 已变，则不自销毁。
class _PendingProtectedPrefWrite {
  String value;
  Timer? timer;
  Future<void> writeChain = Future<void>.value();
  int generation = 0;

  _PendingProtectedPrefWrite(this.value);
}

/// AI 连接参数：API 地址、模型、超时、DeepSeek 思考开关、Web 搜索等
class AiConnectionSettings {
  final String baseUrl;
  final String model;
  final int contextWindowTokens;
  final int timeoutSeconds;
  final bool deepSeekThinkingEnabled;
  final String deepSeekReasoningEffort;
  final bool webSearchEnabled;
  final String webSearchProvider;
  final String webSearchBaseUrl;
  final int webSearchMaxResults;
  final bool hasApiKey;

  const AiConnectionSettings({
    required this.baseUrl,
    required this.model,
    required this.contextWindowTokens,
    required this.timeoutSeconds,
    required this.deepSeekThinkingEnabled,
    required this.deepSeekReasoningEffort,
    required this.webSearchEnabled,
    required this.webSearchProvider,
    required this.webSearchBaseUrl,
    required this.webSearchMaxResults,
    required this.hasApiKey,
  });
}

class AiWebSearchProvider {
  static const String searxng = 'searxng';
  static const String defaultProvider = searxng;
  static const List<String> values = [searxng];

  static String normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return values.contains(normalized) ? normalized! : defaultProvider;
  }

  static String label(String value) {
    return normalize(value) == searxng ? 'SearXNG' : value;
  }
}

class AiWebSearchMaxResults {
  static const int defaultValue = 5;
  static const List<int> values = [3, 5, 8, 10];

  static int normalize(int? value) {
    if (value == null) return defaultValue;
    return value.clamp(values.first, values.last).toInt();
  }
}

class DeepSeekReasoningEffort {
  static const String high = 'high';
  static const String max = 'max';
  static const String defaultEffort = high;
  static const List<String> values = [high, max];

  static String normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return values.contains(normalized) ? normalized! : defaultEffort;
  }

  static String label(String value) {
    return normalize(value) == max ? 'Max' : 'High';
  }
}

/// 内存中缓存一个秘密值及其加载时间，配合 TTL 用
class _MemorySecret {
  final String? value;
  final DateTime loadedAt;

  const _MemorySecret({
    required this.value,
    required this.loadedAt,
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

/// AI 技能定义：用户可自定 system prompts 作为独立技能
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

/// AI 聊天记录：包含标题、模型、消息列表
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

/// 单条 AI 聊天消息，含 Token 用量和推理链路追踪
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

/// 推理追踪数据：记录 tool 请求/响应、审批、思考过程等
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

/// 可恢复的 tmux 会话：保存会话名和字体大小，用于 App 重启后自动 attach
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

/// 终端历史记录：记录终端会话的连接信息和最终状态
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
