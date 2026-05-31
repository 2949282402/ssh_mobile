import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/connection.dart';
import '../models/playbook.dart';
import 'app_log_service.dart';
import 'data_protection_service.dart';
import 'multi_agent_coordinator.dart';

const Uuid _traceUuid = Uuid();

List<AiChatRecord> upsertAiChatRecordsByUpdatedAt(
  Iterable<AiChatRecord> chats,
  AiChatRecord chat, {
  int? limit,
}) {
  final ordered = <AiChatRecord>[];
  var inserted = false;
  for (final item in chats) {
    if (item.id == chat.id) {
      continue;
    }
    if (!inserted && !chat.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(chat);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) {
    ordered.add(chat);
  }
  if (limit != null && ordered.length > limit) {
    ordered.removeRange(limit, ordered.length);
  }
  return ordered;
}

List<AiSkillRecord> upsertAiSkillRecordsByUpdatedAt(
  Iterable<AiSkillRecord> skills,
  AiSkillRecord skill,
) {
  final ordered = <AiSkillRecord>[];
  var inserted = false;
  for (final item in skills) {
    if (item.id == skill.id) {
      continue;
    }
    if (!inserted && !skill.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(skill);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) {
    ordered.add(skill);
  }
  return ordered;
}

List<Playbook> upsertPlaybooksByUpdatedAt(
  Iterable<Playbook> playbooks,
  Playbook playbook,
) {
  final ordered = <Playbook>[];
  var inserted = false;
  for (final item in playbooks) {
    if (item.id == playbook.id) {
      continue;
    }
    if (!inserted && !playbook.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(playbook);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) {
    ordered.add(playbook);
  }
  return ordered;
}

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
abstract interface class AiChatRepository {
  Future<List<AiChatRecord>> loadAiChats();

  Future<void> saveAiChat(AiChatRecord chat);

  Future<void> deleteAiChat(String id);
}

abstract interface class AiSkillRepository {
  Future<List<AiSkillRecord>> loadAiSkills();

  Future<void> saveAiSkill(AiSkillRecord skill);

  Future<void> deleteAiSkill(String id);
}

abstract interface class TerminalHistoryRepository {
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords();

  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record);

  Future<void> removeTerminalHistoryRecord(String sessionId);
}

abstract interface class PlaybookRepository {
  Future<List<Playbook>> loadPlaybooks();

  Future<void> savePlaybook(Playbook playbook);

  Future<void> deletePlaybook(String id);
}

abstract interface class AppBackupRepository {
  Future<String> exportAppDataJson();

  Future<void> importAppDataJson(String jsonText);
}

class StorageService extends ChangeNotifier
    implements
        AiChatRepository,
        AiSkillRepository,
        TerminalHistoryRepository,
        PlaybookRepository,
        AppBackupRepository {
  static const _connectionsKey = 'ssh_connections';
  static const _powerGuideSeenKey = 'power_guide_seen';
  static const _restorableTmuxSessionsKey = 'restorable_tmux_sessions';
  static const _terminalHistoryRecordsKey = 'terminal_history_records';
  static const _aiBaseUrlKey = 'ai_base_url';
  static const _aiBaseUrlHistoryKey = 'ai_base_url_history';
  static const _aiModelKey = 'ai_model';
  static const _aiContextWindowKey = 'ai_context_window';
  static const _aiTimeoutSecondsKey = 'ai_timeout_seconds';
  static const _aiDeepSeekThinkingEnabledKey = 'ai_deepseek_thinking_enabled';
  static const _aiDeepSeekReasoningEffortKey = 'ai_deepseek_reasoning_effort';
  static const _aiOpenAiReasoningEffortKey = 'ai_openai_reasoning_effort';
  static const _aiWebSearchEnabledKey = 'ai_web_search_enabled';
  static const _aiWebSearchMaxResultsKey = 'ai_web_search_max_results';
  static const _aiWebSearchEngineKey = 'ai_web_search_engine';
  static const _aiQuarkSearchEndpointKey = 'ai_quark_search_endpoint';
  static const _quarkApiKeySecureKey = 'ai_quark_api_key';
  static const _aliyunApiKeySecureKey = 'ai_aliyun_api_key';
  static const _aiMultiAgentEnabledKey = 'ai_multi_agent_enabled';
  static const _aiMultiAgentMaxAgentsKey = 'ai_multi_agent_max_agents';
  static const _aiMaxImageSizeBytesKey = 'ai_max_image_size_bytes';
  static const _aiMaxFileSizeBytesKey = 'ai_max_file_size_bytes';
  static const _aiModelsCacheKey = 'ai_models_cache';
  static const _aiApiKeyRefsKey = 'ai_api_key_refs';
  static const _aiSelectedApiKeyIdKey = 'ai_selected_api_key_id';
  static const _aiApiKeyKey = 'ai_api_key';
  static const _aiApiKeyEntryPrefix = 'ai_api_key_entry_';
  static const _aiChatsKey = 'ai_chats';
  static const _aiSkillsKey = 'ai_skills';
  static const _playbooksKey = 'custom_playbooks';
  static const _secretCacheEnabledKey = 'secret_cache_enabled';
  static const _secretCacheTtlSecondsKey = 'secret_cache_ttl_seconds';
  static const _defaultSecretCacheTtl = Duration(minutes: 15);
  static const _protectedPrefWriteDebounce =
      Duration(milliseconds: 700); // 防抖窗口
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
  List<Playbook>? _playbooksCache;
  List<RestorableTmuxSession>? _restorableTmuxSessionsCache;
  List<TerminalHistoryRecord>? _terminalHistoryRecordsCache;
  bool _initialized = false;
  bool _powerGuideSeen = false;
  bool _secretCacheEnabled = true;
  Duration _secretCacheTtl = const Duration(minutes: 15);
  // 内存缓存：密码/私钥/API Key 的 in-memory TTL 缓存，减少 Keychain 访问
  final Map<String, _MemorySecret> _secretCache = {};

  final List<VoidCallback> _onImportCallbacks = [];

  void registerOnImportCallback(VoidCallback callback) {
    _onImportCallbacks.add(callback);
  }

  void unregisterOnImportCallback(VoidCallback callback) {
    _onImportCallbacks.remove(callback);
  }

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
    final openAiReasoningEffort = OpenAiReasoningEffort.normalize(
      _prefs?.getString(_aiOpenAiReasoningEffortKey),
    );
    final webSearchEngine = AiWebSearchEngine.normalize(
      _prefs?.getString(_aiWebSearchEngineKey),
    );
    final quarkSearchEndpoint =
        _prefs?.getString(_aiQuarkSearchEndpointKey)?.trim() ??
            'https://dashscope.aliyuncs.com/api/v1/services/search/quark';
    final quarkApiKey = await getQuarkApiKey();
    final hasQuarkApiKey = quarkApiKey?.isNotEmpty == true;
    final apiKey = await getAiApiKey();
    final activeApiKeyId = await getSelectedAiApiKeyId();
    final activeApiKeyMasked =
        apiKey?.isNotEmpty == true ? maskAiApiKey(apiKey!) : null;
    return AiConnectionSettings(
      baseUrl:
          baseUrl?.isNotEmpty == true ? baseUrl! : 'https://api.deepseek.com',
      model: model?.isNotEmpty == true ? model! : 'deepseek-v4-flash',
      contextWindowTokens: AiContextWindowSize.normalize(contextWindow),
      timeoutSeconds: await getAiRequestTimeoutSeconds(),
      deepSeekThinkingEnabled: thinkingEnabled,
      deepSeekReasoningEffort: reasoningEffort,
      openAiReasoningEffort: openAiReasoningEffort,
      webSearchEnabled: _prefs?.getBool(_aiWebSearchEnabledKey) ?? true,
      webSearchMaxResults: AiWebSearchMaxResults.normalize(
        _prefs?.getInt(_aiWebSearchMaxResultsKey),
      ),
      webSearchEngine: webSearchEngine,
      quarkSearchEndpoint: quarkSearchEndpoint,
      hasQuarkApiKey: hasQuarkApiKey,
      multiAgentEnabled: _prefs?.getBool(_aiMultiAgentEnabledKey) ?? true,
      multiAgentMaxAgents: AiMultiAgentMaxAgents.normalize(
        _prefs?.getInt(_aiMultiAgentMaxAgentsKey),
      ),
      maxImageSizeBytes: AiUploadSizeLimit.normalizeImage(
        _prefs?.getInt(_aiMaxImageSizeBytesKey),
      ),
      maxFileSizeBytes: AiUploadSizeLimit.normalizeFile(
        _prefs?.getInt(_aiMaxFileSizeBytesKey),
      ),
      hasApiKey: apiKey?.isNotEmpty == true,
      activeApiKeyId: activeApiKeyId,
      activeApiKeyMasked: activeApiKeyMasked,
    );
  }

  Future<List<String>> loadCachedAiModels({String? baseUrl}) async {
    if (!_initialized || _prefs == null) return const [];
    final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(
      baseUrl?.trim().isNotEmpty == true
          ? baseUrl!
          : (_prefs!.getString(_aiBaseUrlKey) ?? 'https://api.deepseek.com'),
    );
    if (normalizedBaseUrl.isEmpty) return const [];
    final cache = _readAiModelsCacheMap();
    return List.unmodifiable(cache[normalizedBaseUrl] ?? const <String>[]);
  }

  Future<List<String>> loadAiBaseUrlHistory() async {
    if (!_initialized || _prefs == null) return const [];
    final currentBaseUrl = _prefs?.getString(_aiBaseUrlKey);
    return List.unmodifiable(
      _normalizeAiBaseUrlHistory(
        _readStringListPref(_aiBaseUrlHistoryKey),
        prependValue: currentBaseUrl,
      ),
    );
  }

  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) async {
    if (!_initialized || _prefs == null) return;
    final normalizedTarget = _normalizeAiModelsCacheBaseUrl(baseUrl);
    if (normalizedTarget.isEmpty) return;
    final nextHistory = _normalizeAiBaseUrlHistory(
      _readStringListPref(_aiBaseUrlHistoryKey),
    )..remove(normalizedTarget);
    await _writeStringListPref(_aiBaseUrlHistoryKey, nextHistory);
  }

  Future<List<AiApiKeyHistoryEntry>> loadAiApiKeyHistory() async {
    if (!_initialized || _prefs == null) return const [];
    await _ensureAiApiKeyHistoryMigrated();
    final selectedId = await getSelectedAiApiKeyId();
    final ids = _readAiApiKeyRefIds();
    final entries = <AiApiKeyHistoryEntry>[];
    final staleIds = <String>[];
    for (final id in ids) {
      final value = await _secureStorage.read(key: _aiApiKeyStorageKey(id));
      final normalized = _normalizeAiApiKey(value);
      if (normalized == null) {
        staleIds.add(id);
        if (value != null && value.isNotEmpty) {
          await _secureStorage.delete(key: _aiApiKeyStorageKey(id));
        }
        continue;
      }
      entries.add(
        AiApiKeyHistoryEntry(
          id: id,
          maskedValue: maskAiApiKey(normalized),
          isSelected: id == selectedId,
        ),
      );
    }
    if (staleIds.isNotEmpty) {
      final nextIds = ids.where((id) => !staleIds.contains(id)).toList();
      await _writeAiApiKeyRefIds(nextIds);
      if (selectedId != null && staleIds.contains(selectedId)) {
        await _setSelectedAiApiKeyId(nextIds.isNotEmpty ? nextIds.first : null);
      }
    }
    return List.unmodifiable(entries);
  }

  Future<String?> getAiApiKeyById(String id) async {
    if (!_initialized) return null;
    await _ensureAiApiKeyHistoryMigrated();
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) return null;
    final value =
        await _secureStorage.read(key: _aiApiKeyStorageKey(normalizedId));
    return _normalizeAiApiKey(value);
  }

  Future<void> removeAiApiKeyHistoryEntry(String id) async {
    if (!_initialized || _prefs == null) return;
    await _ensureAiApiKeyHistoryMigrated();
    final ids = _readAiApiKeyRefIds();
    if (!ids.contains(id)) return;
    final nextIds = ids.where((item) => item != id).toList();
    await _secureStorage.delete(key: _aiApiKeyStorageKey(id));
    await _writeAiApiKeyRefIds(nextIds);
    final selectedId = _prefs?.getString(_aiSelectedApiKeyIdKey)?.trim();
    if (selectedId == id) {
      await _setSelectedAiApiKeyId(nextIds.isNotEmpty ? nextIds.first : null);
    }
    _secretCache.remove(_memoryAiApiKeyCacheKey);
  }

  Future<String?> getSelectedAiApiKeyId() async {
    if (!_initialized || _prefs == null) return null;
    await _ensureAiApiKeyHistoryMigrated();
    final ids = _readAiApiKeyRefIds();
    if (ids.isEmpty) {
      await _setSelectedAiApiKeyId(null);
      return null;
    }
    final selectedId = _prefs?.getString(_aiSelectedApiKeyIdKey)?.trim();
    if (selectedId != null && ids.contains(selectedId)) {
      return selectedId;
    }
    final fallbackId = ids.first;
    await _setSelectedAiApiKeyId(fallbackId);
    return fallbackId;
  }

  Future<void> saveCachedAiModels({
    required String baseUrl,
    required Iterable<String> models,
  }) async {
    if (!_initialized || _prefs == null) return;
    final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(baseUrl);
    if (normalizedBaseUrl.isEmpty) return;
    final normalizedModels = _normalizeAiModelList(models);
    final cache = _readAiModelsCacheMap();
    if (normalizedModels.isEmpty) {
      cache.remove(normalizedBaseUrl);
    } else {
      cache[normalizedBaseUrl] = normalizedModels;
    }
    await _prefs!.setString(_aiModelsCacheKey, jsonEncode(cache));
  }

  Future<void> clearCachedAiModels({String? baseUrl}) async {
    if (!_initialized || _prefs == null) return;
    if (baseUrl == null) {
      await _prefs!.remove(_aiModelsCacheKey);
      return;
    }
    final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(baseUrl);
    if (normalizedBaseUrl.isEmpty) return;
    final cache = _readAiModelsCacheMap();
    cache.remove(normalizedBaseUrl);
    if (cache.isEmpty) {
      await _prefs!.remove(_aiModelsCacheKey);
      return;
    }
    await _prefs!.setString(_aiModelsCacheKey, jsonEncode(cache));
  }

  Future<int> getAiRequestTimeoutSeconds() async {
    return AiRequestTimeout.normalize(_prefs?.getInt(_aiTimeoutSecondsKey));
  }

  Future<String?> getAiApiKey() async {
    if (!_initialized) return null;
    await _ensureAiApiKeyHistoryMigrated();
    final cache = _readCachedSecretEntry(_memoryAiApiKeyCacheKey);
    if (cache != null) return cache.value;

    while (true) {
      final selectedId = await getSelectedAiApiKeyId();
      if (selectedId == null) {
        _secretCache.remove(_memoryAiApiKeyCacheKey);
        return null;
      }
      final value =
          await _secureStorage.read(key: _aiApiKeyStorageKey(selectedId));
      final normalized = _normalizeAiApiKey(value);
      if (value != null && value.isNotEmpty && normalized == null) {
        await removeAiApiKeyHistoryEntry(selectedId);
        AppLogService.instance.warning(
          'Invalid LLM API key cleared',
          details:
              'Stored key contained characters that cannot be used safely.',
        );
        continue;
      }
      if (_secretCacheEnabled) {
        _secretCache[_memoryAiApiKeyCacheKey] = _MemorySecret(
          value: normalized,
          loadedAt: DateTime.now(),
        );
      }
      return normalized;
    }
  }

  Future<String?> getQuarkApiKey() async {
    if (!_initialized) return null;
    final value = await _secureStorage.read(key: _quarkApiKeySecureKey);
    return value?.trim();
  }

  Future<String?> getAliyunApiKey() async {
    if (!_initialized) return null;
    final value = await _secureStorage.read(key: _aliyunApiKeySecureKey);
    return value?.trim();
  }

  Future<void> saveAliyunApiKey(String key) async {
    if (!_initialized) return;
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _secureStorage.delete(key: _aliyunApiKeySecureKey);
    } else {
      await _secureStorage.write(key: _aliyunApiKeySecureKey, value: trimmed);
    }
  }

  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    int? contextWindowTokens,
    int? timeoutSeconds,
    bool? deepSeekThinkingEnabled,
    String? deepSeekReasoningEffort,
    String? openAiReasoningEffort,
    bool? webSearchEnabled,
    int? webSearchMaxResults,
    String? webSearchEngine,
    bool? multiAgentEnabled,
    int? multiAgentMaxAgents,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    String? apiKey,
    String? selectedApiKeyId,
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
  }) async {
    if (!_initialized || _prefs == null) return;
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = model.trim();
    await _prefs!.setString(_aiBaseUrlKey, normalizedBaseUrl);
    await _persistAiBaseUrlHistory(normalizedBaseUrl);
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
    await _prefs!.setString(
      _aiOpenAiReasoningEffortKey,
      OpenAiReasoningEffort.normalize(
        openAiReasoningEffort ?? _prefs!.getString(_aiOpenAiReasoningEffortKey),
      ),
    );
    await _prefs!.setBool(
      _aiWebSearchEnabledKey,
      webSearchEnabled ?? (_prefs!.getBool(_aiWebSearchEnabledKey) ?? true),
    );
    await _prefs!.setInt(
      _aiWebSearchMaxResultsKey,
      AiWebSearchMaxResults.normalize(
        webSearchMaxResults ?? _prefs!.getInt(_aiWebSearchMaxResultsKey),
      ),
    );
    await _prefs!.setString(
      _aiWebSearchEngineKey,
      AiWebSearchEngine.normalize(
        webSearchEngine ?? _prefs!.getString(_aiWebSearchEngineKey),
      ),
    );
    if (quarkSearchEndpoint != null) {
      await _prefs!
          .setString(_aiQuarkSearchEndpointKey, quarkSearchEndpoint.trim());
    }
    await _prefs!.setBool(
      _aiMultiAgentEnabledKey,
      multiAgentEnabled ?? (_prefs!.getBool(_aiMultiAgentEnabledKey) ?? true),
    );
    await _prefs!.setInt(
      _aiMultiAgentMaxAgentsKey,
      AiMultiAgentMaxAgents.normalize(
        multiAgentMaxAgents ?? _prefs!.getInt(_aiMultiAgentMaxAgentsKey),
      ),
    );
    await _prefs!.setInt(
      _aiMaxImageSizeBytesKey,
      AiUploadSizeLimit.normalizeImage(
        maxImageSizeBytes ?? _prefs!.getInt(_aiMaxImageSizeBytesKey),
      ),
    );
    await _prefs!.setInt(
      _aiMaxFileSizeBytesKey,
      AiUploadSizeLimit.normalizeFile(
        maxFileSizeBytes ?? _prefs!.getInt(_aiMaxFileSizeBytesKey),
      ),
    );
    await _ensureAiApiKeyHistoryMigrated();
    var apiKeyUpdated = false;
    final hasReplacementApiKey = apiKey?.trim().isNotEmpty == true;
    if (hasReplacementApiKey) {
      final replacementApiKey = apiKey!;
      final normalizedApiKey = _normalizeAiApiKey(apiKey);
      if (normalizedApiKey == null) {
        AppLogService.instance.warning(
          'LLM settings rejected invalid API key',
          details:
              'baseUrl=$normalizedBaseUrl model=$normalizedModel inputLength=${replacementApiKey.length}',
        );
        throw const FormatException('Invalid API key format.');
      }
      final selectedId = await _upsertAiApiKeyHistoryEntry(normalizedApiKey);
      await _setSelectedAiApiKeyId(selectedId);
      if (_secretCacheEnabled) {
        _secretCache[_memoryAiApiKeyCacheKey] = _MemorySecret(
          value: normalizedApiKey,
          loadedAt: DateTime.now(),
        );
      }
      apiKeyUpdated = true;
    } else if (selectedApiKeyId?.trim().isNotEmpty == true) {
      await _setSelectedAiApiKeyId(selectedApiKeyId!.trim());
      _secretCache.remove(_memoryAiApiKeyCacheKey);
    } else if (clearApiKey) {
      final currentId = await getSelectedAiApiKeyId();
      if (currentId != null) {
        await removeAiApiKeyHistoryEntry(currentId);
      } else {
        await _clearLegacyAiApiKeySecret();
      }
      apiKeyUpdated = true;
    }

    var quarkApiKeyUpdated = false;
    if (quarkApiKey != null) {
      final trimmed = quarkApiKey.trim();
      if (trimmed.isNotEmpty) {
        await _secureStorage.write(key: _quarkApiKeySecureKey, value: trimmed);
        quarkApiKeyUpdated = true;
      } else {
        await _secureStorage.delete(key: _quarkApiKeySecureKey);
        quarkApiKeyUpdated = true;
      }
    } else if (clearQuarkApiKey) {
      await _secureStorage.delete(key: _quarkApiKeySecureKey);
      quarkApiKeyUpdated = true;
    }
    AppLogService.instance.info(
      'LLM settings saved',
      details:
          'baseUrl=$normalizedBaseUrl model=$normalizedModel contextWindow=${AiContextWindowSize.normalize(contextWindowTokens)} timeoutSeconds=${AiRequestTimeout.normalize(timeoutSeconds)} deepSeekThinking=${deepSeekThinkingEnabled ?? (_prefs!.getBool(_aiDeepSeekThinkingEnabledKey) ?? true)} deepSeekEffort=${DeepSeekReasoningEffort.normalize(deepSeekReasoningEffort ?? _prefs!.getString(_aiDeepSeekReasoningEffortKey))} openAiEffort=${OpenAiReasoningEffort.normalize(openAiReasoningEffort ?? _prefs!.getString(_aiOpenAiReasoningEffortKey))} webSearch=${webSearchEnabled ?? (_prefs!.getBool(_aiWebSearchEnabledKey) ?? true)} webSearchEngine=${AiWebSearchEngine.normalize(webSearchEngine ?? _prefs!.getString(_aiWebSearchEngineKey))} quarkSearchEndpoint=${_prefs!.getString(_aiQuarkSearchEndpointKey)} quarkApiKeyUpdated=$quarkApiKeyUpdated multiAgent=${multiAgentEnabled ?? (_prefs!.getBool(_aiMultiAgentEnabledKey) ?? true)} maxAgents=${AiMultiAgentMaxAgents.normalize(multiAgentMaxAgents ?? _prefs!.getInt(_aiMultiAgentMaxAgentsKey))} apiKeyUpdated=$apiKeyUpdated',
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

  Future<void> _clearAiApiKeySecret() async {
    _secretCache.remove(_memoryAiApiKeyCacheKey);
    await _clearLegacyAiApiKeySecret();
    final ids = _readAiApiKeyRefIds();
    for (final id in ids) {
      await _secureStorage.delete(key: _aiApiKeyStorageKey(id));
    }
    await _writeAiApiKeyRefIds(const []);
    await _setSelectedAiApiKeyId(null);
  }

  Future<void> _clearLegacyAiApiKeySecret() async {
    _secretCache.remove(_memoryAiApiKeyCacheKey);
    await _secureStorage.delete(key: _aiApiKeyKey);
  }

  Future<void> _ensureAiApiKeyHistoryMigrated() async {
    if (!_initialized || _prefs == null) return;
    if (_readAiApiKeyRefIds().isNotEmpty) return;
    final legacyValue = await _secureStorage.read(key: _aiApiKeyKey);
    final normalizedLegacy = _normalizeAiApiKey(legacyValue);
    if (normalizedLegacy == null) {
      if (legacyValue != null && legacyValue.isNotEmpty) {
        await _secureStorage.delete(key: _aiApiKeyKey);
      }
      return;
    }
    final id = _traceUuid.v4();
    await _secureStorage.write(
      key: _aiApiKeyStorageKey(id),
      value: normalizedLegacy,
    );
    await _writeAiApiKeyRefIds([id]);
    await _setSelectedAiApiKeyId(id);
    await _secureStorage.delete(key: _aiApiKeyKey);
  }

  Future<String> _upsertAiApiKeyHistoryEntry(String apiKey) async {
    final normalizedApiKey = _normalizeAiApiKey(apiKey);
    if (normalizedApiKey == null) {
      throw const FormatException('Invalid API key format.');
    }
    final ids = _readAiApiKeyRefIds();
    String? matchedId;
    for (final id in ids) {
      final value = await _secureStorage.read(key: _aiApiKeyStorageKey(id));
      if (_normalizeAiApiKey(value) == normalizedApiKey) {
        matchedId = id;
        break;
      }
    }
    final targetId = matchedId ?? _traceUuid.v4();
    await _secureStorage.write(
      key: _aiApiKeyStorageKey(targetId),
      value: normalizedApiKey,
    );
    final nextIds = <String>[
      targetId,
      ...ids.where((id) => id != targetId),
    ];
    await _writeAiApiKeyRefIds(nextIds);
    return targetId;
  }

  Future<void> _setSelectedAiApiKeyId(String? id) async {
    if (_prefs == null) return;
    final normalized = id?.trim();
    if (normalized == null || normalized.isEmpty) {
      await _prefs!.remove(_aiSelectedApiKeyIdKey);
      return;
    }
    await _prefs!.setString(_aiSelectedApiKeyIdKey, normalized);
  }

  List<String> _readAiApiKeyRefIds() {
    return _readStringListPref(_aiApiKeyRefsKey);
  }

  Future<void> _writeAiApiKeyRefIds(List<String> ids) async {
    await _writeStringListPref(_aiApiKeyRefsKey, ids);
  }

  String _aiApiKeyStorageKey(String id) => '$_aiApiKeyEntryPrefix$id';

  Future<void> _persistAiBaseUrlHistory(String currentBaseUrl) async {
    await _writeStringListPref(
      _aiBaseUrlHistoryKey,
      _normalizeAiBaseUrlHistory(
        _readStringListPref(_aiBaseUrlHistoryKey),
        prependValue: currentBaseUrl,
      ),
    );
  }

  List<String> _readStringListPref(String key) {
    final raw = _prefs?.getString(key);
    if (raw == null || raw.trim().isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded.whereType<String>().toList();
    } catch (_) {
      return <String>[];
    }
  }

  Future<void> _writeStringListPref(String key, List<String> values) async {
    if (_prefs == null) return;
    if (values.isEmpty) {
      await _prefs!.remove(key);
      return;
    }
    await _prefs!.setString(key, jsonEncode(values));
  }

  List<String> _normalizeAiBaseUrlHistory(
    Iterable<String> history, {
    String? prependValue,
  }) {
    final seen = <String>{};
    final normalized = <String>[];
    void addValue(String value) {
      final item = _normalizeAiModelsCacheBaseUrl(value);
      if (item.isEmpty || !seen.add(item)) return;
      normalized.add(item);
    }

    if (prependValue != null) {
      addValue(prependValue);
    }
    for (final item in history) {
      addValue(item);
    }
    return normalized;
  }

  Map<String, List<String>> _readAiModelsCacheMap() {
    final raw = _prefs?.getString(_aiModelsCacheKey);
    if (raw == null || raw.trim().isEmpty) {
      return <String, List<String>>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return <String, List<String>>{};
      }
      final cache = <String, List<String>>{};
      for (final entry in decoded.entries) {
        final normalizedBaseUrl = _normalizeAiModelsCacheBaseUrl(entry.key);
        if (normalizedBaseUrl.isEmpty || entry.value is! List) continue;
        final normalizedModels = _normalizeAiModelList(
          (entry.value as List).whereType<String>(),
        );
        if (normalizedModels.isNotEmpty) {
          cache[normalizedBaseUrl] = normalizedModels;
        }
      }
      return cache;
    } catch (_) {
      return <String, List<String>>{};
    }
  }

  List<String> _normalizeAiModelList(Iterable<String> models) {
    return models
        .map((model) => model.trim())
        .where((model) => model.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  String _normalizeAiModelsCacheBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  @override
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
      AppLogService.instance.error('Failed to load AI chats', error: e);
      return _aiChatsCache = const [];
    }
  }

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    if (!_initialized || _prefs == null) return;
    final chats = upsertAiChatRecordsByUpdatedAt(
      await loadAiChats(),
      chat,
      limit: 80,
    );
    await _saveAiChats(chats, alreadySorted: true);
    notifyListeners();
  }

  @override
  Future<void> deleteAiChat(String id) async {
    if (!_initialized || _prefs == null) return;
    final chats = (await loadAiChats())
        .where((item) => item.id != id)
        .toList(growable: false);
    await _saveAiChats(chats, alreadySorted: true);
    notifyListeners();
  }

  @override
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
      AppLogService.instance.error('Failed to load AI skills', error: e);
      return _aiSkillsCache = const [];
    }
  }

  @override
  Future<void> saveAiSkill(AiSkillRecord skill) async {
    if (!_initialized || _prefs == null) return;
    final skills = upsertAiSkillRecordsByUpdatedAt(
      await loadAiSkills(),
      skill,
    );
    await _saveAiSkills(skills, alreadySorted: true);
    notifyListeners();
  }

  @override
  Future<void> deleteAiSkill(String id) async {
    if (!_initialized || _prefs == null) return;
    final skills = (await loadAiSkills())
        .where((item) => item.id != id)
        .toList(growable: false);
    await _saveAiSkills(skills, alreadySorted: true);
    notifyListeners();
  }

  @override
  Future<List<Playbook>> loadPlaybooks() async {
    if (!_initialized || _prefs == null) return [];
    final cached = _playbooksCache;
    if (cached != null) return cached;
    final jsonStr = await _readProtectedPref(_playbooksKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return _playbooksCache = const [];
    }

    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final playbooks = list
          .map((item) => Playbook.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return _playbooksCache = List.unmodifiable(playbooks);
    } catch (e) {
      AppLogService.instance.error('Failed to load playbooks', error: e);
      return _playbooksCache = const [];
    }
  }

  @override
  Future<void> savePlaybook(Playbook playbook) async {
    if (!_initialized || _prefs == null) return;
    final playbooks = upsertPlaybooksByUpdatedAt(
      await loadPlaybooks(),
      playbook,
    );
    await _savePlaybooks(playbooks, alreadySorted: true);
    notifyListeners();
  }

  @override
  Future<void> deletePlaybook(String id) async {
    if (!_initialized || _prefs == null) return;
    final playbooks = (await loadPlaybooks())
        .where((item) => item.id != id)
        .toList(growable: false);
    await _savePlaybooks(playbooks, alreadySorted: true);
    notifyListeners();
  }

  /// 导出所有用户数据为 JSON 格式。
  /// 注意：密码/私钥/API Key 置空，不包含在导出中。
  @override
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
      'version': 2,
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
        'openAiReasoningEffort': settings.openAiReasoningEffort,
        'webSearchEnabled': settings.webSearchEnabled,
        'webSearchMaxResults': settings.webSearchMaxResults,
        'webSearchEngine': settings.webSearchEngine,
        'quarkSearchEndpoint': settings.quarkSearchEndpoint,
        'multiAgentEnabled': settings.multiAgentEnabled,
        'multiAgentMaxAgents': settings.multiAgentMaxAgents,
        'maxImageSizeBytes': settings.maxImageSizeBytes,
        'maxFileSizeBytes': settings.maxFileSizeBytes,
        'apiKey': '',
      },
      'appSettings': {
        'language': _prefs!.getString('app_language'),
        'themeMode': _prefs!.getString('theme_mode'),
        'darkMode': _prefs!.getBool('dark_mode'),
        'fontFamily': _prefs!.getString('font_family'),
        'sftpDownloadLimitBytes': _prefs!.getInt('sftp_download_limit_bytes'),
        'sftpTextPreviewLimitBytes': _prefs!.getInt('sftp_text_preview_limit_bytes'),
        'sftpRichPreviewLimitBytes': _prefs!.getInt('sftp_rich_preview_limit_bytes'),
        'sftpTextEditLimitBytes': _prefs!.getInt('sftp_text_edit_limit_bytes'),
      },
      'shortcutCommands': {
        'usage': _prefs!.getString('shortcut_command_usage'),
        'customCommands': _prefs!.getString('custom_shortcut_commands'),
        'order': _prefs!.getString('shortcut_command_order'),
      },
      'secretCache': {
        'enabled': _prefs!.getBool('secret_cache_enabled'),
        'ttlSeconds': _prefs!.getInt('secret_cache_ttl_seconds'),
      },
      'aiChats': (await loadAiChats()).map((item) => item.toJson()).toList(),
      'aiSkills': (await loadAiSkills()).map((item) => item.toJson()).toList(),
      'playbooks':
          (await loadPlaybooks()).map((item) => item.toJson()).toList(),
      'powerGuideSeen': _powerGuideSeen,
    };
    AppLogService.instance.info(
      'App data exported',
      details:
          'connections=${connectionPayloads.length} chats=${(payload['aiChats'] as List).length} skills=${(payload['aiSkills'] as List).length} playbooks=${(payload['playbooks'] as List).length} secrets=omitted',
    );
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 从 JSON 备份导入所有用户数据。
  /// 格式校验：必须包含 'ssh_mobile_backup' 标记。
  @override
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
    await clearCachedAiModels();
    await _writeStringListPref(_aiBaseUrlHistoryKey, const []);

    final aiSettings = decoded['aiSettings'];
    if (aiSettings is Map<String, dynamic>) {
      // Backups are not a credential transport. Clear any current cached key
      // and ignore hand-edited or legacy apiKey values from imported files.
      await saveAiConnectionSettings(
        baseUrl: aiSettings['baseUrl'] as String? ?? 'https://api.deepseek.com',
        model: aiSettings['model'] as String? ?? 'deepseek-v4-flash',
        contextWindowTokens:
            (aiSettings['contextWindowTokens'] as num?)?.toInt(),
        timeoutSeconds: (aiSettings['timeoutSeconds'] as num?)?.toInt(),
        deepSeekThinkingEnabled: aiSettings['deepSeekThinkingEnabled'] as bool?,
        deepSeekReasoningEffort:
            aiSettings['deepSeekReasoningEffort'] as String?,
        openAiReasoningEffort: aiSettings['openAiReasoningEffort'] as String?,
        webSearchEnabled: aiSettings['webSearchEnabled'] as bool?,
        webSearchMaxResults:
            (aiSettings['webSearchMaxResults'] as num?)?.toInt(),
        webSearchEngine: aiSettings['webSearchEngine'] as String?,
        quarkSearchEndpoint: aiSettings['quarkSearchEndpoint'] as String?,
        multiAgentEnabled: aiSettings['multiAgentEnabled'] as bool?,
        multiAgentMaxAgents:
            (aiSettings['multiAgentMaxAgents'] as num?)?.toInt(),
        maxImageSizeBytes: (aiSettings['maxImageSizeBytes'] as num?)?.toInt(),
        maxFileSizeBytes: (aiSettings['maxFileSizeBytes'] as num?)?.toInt(),
      );
      await _clearAiApiKeySecret();
      await _secureStorage.delete(key: _quarkApiKeySecureKey);
    } else {
      await _clearAiApiKeySecret();
      await _secureStorage.delete(key: _quarkApiKeySecureKey);
    }

    final appSettings = decoded['appSettings'];
    if (appSettings is Map<String, dynamic>) {
      if (appSettings['language'] != null) {
        await _prefs!.setString('app_language', appSettings['language'] as String);
      }
      if (appSettings['themeMode'] != null) {
        await _prefs!.setString('theme_mode', appSettings['themeMode'] as String);
      }
      if (appSettings['darkMode'] != null) {
        await _prefs!.setBool('dark_mode', appSettings['darkMode'] as bool);
      }
      if (appSettings['fontFamily'] != null) {
        await _prefs!.setString('font_family', appSettings['fontFamily'] as String);
      }
      if (appSettings['sftpDownloadLimitBytes'] != null) {
        await _prefs!.setInt('sftp_download_limit_bytes', (appSettings['sftpDownloadLimitBytes'] as num).toInt());
      }
      if (appSettings['sftpTextPreviewLimitBytes'] != null) {
        await _prefs!.setInt('sftp_text_preview_limit_bytes', (appSettings['sftpTextPreviewLimitBytes'] as num).toInt());
      }
      if (appSettings['sftpRichPreviewLimitBytes'] != null) {
        await _prefs!.setInt('sftp_rich_preview_limit_bytes', (appSettings['sftpRichPreviewLimitBytes'] as num).toInt());
      }
      if (appSettings['sftpTextEditLimitBytes'] != null) {
        await _prefs!.setInt('sftp_text_edit_limit_bytes', (appSettings['sftpTextEditLimitBytes'] as num).toInt());
      }
    }

    final shortcutCommands = decoded['shortcutCommands'];
    if (shortcutCommands is Map<String, dynamic>) {
      if (shortcutCommands['usage'] != null) {
        await _prefs!.setString('shortcut_command_usage', shortcutCommands['usage'] as String);
      }
      if (shortcutCommands['customCommands'] != null) {
        await _prefs!.setString('custom_shortcut_commands', shortcutCommands['customCommands'] as String);
      }
      if (shortcutCommands['order'] != null) {
        await _prefs!.setString('shortcut_command_order', shortcutCommands['order'] as String);
      }
    }

    final secretCache = decoded['secretCache'];
    if (secretCache is Map<String, dynamic>) {
      if (secretCache['enabled'] != null) {
        await _prefs!.setBool('secret_cache_enabled', secretCache['enabled'] as bool);
      }
      if (secretCache['ttlSeconds'] != null) {
        await _prefs!.setInt('secret_cache_ttl_seconds', (secretCache['ttlSeconds'] as num).toInt());
      }

      // Update in-memory values immediately
      _secretCacheEnabled = _prefs!.getBool(_secretCacheEnabledKey) ?? true;
      final ttlSeconds = _prefs!.getInt(_secretCacheTtlSecondsKey);
      if (ttlSeconds != null) {
        _secretCacheTtl = _normalizeSecretCacheTtl(Duration(seconds: ttlSeconds));
      } else {
        _secretCacheTtl = _defaultSecretCacheTtl;
      }
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
    await _savePlaybooks(
      ((decoded['playbooks'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Playbook.fromJson)
          .toList(),
      immediate: true,
    );
    _powerGuideSeen = decoded['powerGuideSeen'] as bool? ?? _powerGuideSeen;
    await _prefs?.setBool(_powerGuideSeenKey, _powerGuideSeen);
    AppLogService.instance.info(
      'App data imported',
      details:
          'connections=${_connections.length} chats=${((decoded['aiChats'] as List<dynamic>?) ?? const []).length} skills=${((decoded['aiSkills'] as List<dynamic>?) ?? const []).length} playbooks=${((decoded['playbooks'] as List<dynamic>?) ?? const []).length}',
    );
    for (final callback in _onImportCallbacks) {
      try {
        callback();
      } catch (e) {
        AppLogService.instance.error('Error invoking import callback', error: e);
      }
    }
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

  @override
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
      AppLogService.instance.error(
        'Failed to load terminal history records',
        error: e,
      );
      return _terminalHistoryRecordsCache = const [];
    }
  }

  @override
  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) async {
    if (!_initialized || _prefs == null) return;
    final records = [...await loadTerminalHistoryRecords()];
    records.removeWhere((item) => item.sessionId == record.sessionId);
    records.insert(0, record);
    await _saveTerminalHistoryRecords(records.take(200).toList());
    notifyListeners();
  }

  @override
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
    bool alreadySorted = false,
  }) async {
    final ordered = alreadySorted
        ? List<AiChatRecord>.from(chats, growable: false)
        : ([...chats]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _aiChatsCache = List.unmodifiable(ordered);
    final jsonStr = jsonEncode(ordered.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      _aiChatsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<void> _saveAiSkills(
    List<AiSkillRecord> skills, {
    bool immediate = false,
    bool alreadySorted = false,
  }) async {
    final ordered = alreadySorted
        ? List<AiSkillRecord>.from(skills, growable: false)
        : ([...skills]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _aiSkillsCache = List.unmodifiable(ordered);
    final jsonStr = jsonEncode(ordered.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      _aiSkillsKey,
      jsonStr,
      immediate: immediate,
    );
  }

  Future<void> _savePlaybooks(
    List<Playbook> playbooks, {
    bool immediate = false,
    bool alreadySorted = false,
  }) async {
    final ordered = alreadySorted
        ? List<Playbook>.from(playbooks, growable: false)
        : ([...playbooks]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    _playbooksCache = List.unmodifiable(ordered);
    final jsonStr = jsonEncode(ordered.map((item) => item.toJson()).toList());
    await _writeProtectedPrefBuffered(
      _playbooksKey,
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
  final String openAiReasoningEffort;
  final bool webSearchEnabled;
  final int webSearchMaxResults;
  final String webSearchEngine;
  final String quarkSearchEndpoint;
  final bool hasQuarkApiKey;
  final bool multiAgentEnabled;
  final int multiAgentMaxAgents;
  final int maxImageSizeBytes;
  final int maxFileSizeBytes;
  final bool hasApiKey;
  final String? activeApiKeyId;
  final String? activeApiKeyMasked;

  const AiConnectionSettings({
    required this.baseUrl,
    required this.model,
    required this.contextWindowTokens,
    required this.timeoutSeconds,
    required this.deepSeekThinkingEnabled,
    required this.deepSeekReasoningEffort,
    required this.openAiReasoningEffort,
    required this.webSearchEnabled,
    required this.webSearchMaxResults,
    required this.webSearchEngine,
    required this.quarkSearchEndpoint,
    required this.hasQuarkApiKey,
    required this.multiAgentEnabled,
    required this.multiAgentMaxAgents,
    required this.maxImageSizeBytes,
    required this.maxFileSizeBytes,
    required this.hasApiKey,
    required this.activeApiKeyId,
    required this.activeApiKeyMasked,
  });
}

class AiApiKeyHistoryEntry {
  final String id;
  final String maskedValue;
  final bool isSelected;

  const AiApiKeyHistoryEntry({
    required this.id,
    required this.maskedValue,
    required this.isSelected,
  });
}

class AiWebSearchMaxResults {
  static const int defaultValue = 5;
  static const List<int> values = [3, 5, 8, 10];

  static int normalize(int? value) {
    if (value == null) return defaultValue;
    return value.clamp(values.first, values.last).toInt();
  }
}

class AiWebSearchEngine {
  static const String google = 'google';
  static const String bing = 'bing';
  static const String baidu = 'baidu';
  static const String duckDuckGo = 'duckduckgo';
  static const String quark = 'quark';

  static const String defaultValue = duckDuckGo;

  static const List<String> values = [google, bing, baidu, duckDuckGo, quark];

  static String normalize(String? value) {
    if (value == null) return defaultValue;
    final normalized = value.trim().toLowerCase();
    if (values.contains(normalized)) return normalized;
    return defaultValue;
  }
}

class AiUploadSizeLimit {
  static const int _mb = 1024 * 1024;
  static const int defaultImageSizeBytes = 50 * _mb;
  static const int defaultFileSizeBytes = 50 * _mb;
  static const List<int> imageValues = [
    1 * _mb,
    2 * _mb,
    5 * _mb,
    10 * _mb,
    20 * _mb,
    50 * _mb,
  ];
  static const List<int> fileValues = [
    1 * _mb,
    5 * _mb,
    10 * _mb,
    20 * _mb,
    50 * _mb,
  ];

  static int normalizeImage(int? value) {
    if (value == null) return defaultImageSizeBytes;
    return value.clamp(imageValues.first, imageValues.last);
  }

  static int normalizeFile(int? value) {
    if (value == null) return defaultFileSizeBytes;
    return value.clamp(fileValues.first, fileValues.last);
  }

  static String label(int bytes) {
    if (bytes >= _mb) {
      final mb = bytes ~/ _mb;
      return '$mb MB';
    }
    return '${bytes ~/ 1024} KB';
  }
}

class AiChatAttachment {
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String dataBase64;

  const AiChatAttachment({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.dataBase64,
  });

  bool get isImage => mimeType.startsWith('image/');

  bool get isTextFile {
    if (mimeType.startsWith('text/')) return true;
    const textExtensions = [
      '.json',
      '.xml',
      '.yaml',
      '.yml',
      '.md',
      '.csv',
      '.log',
      '.sh',
      '.py',
      '.js',
      '.dart',
      '.ts',
      '.html',
      '.css',
      '.sql',
      '.ini',
      '.conf',
      '.cfg',
      '.toml',
      '.env',
      '.bat',
      '.ps1',
      '.rb',
      '.go',
      '.rs',
      '.c',
      '.cpp',
      '.h',
      '.java',
      '.kt',
      '.swift',
      '.r',
      '.m',
      '.php',
      '.pl',
    ];
    final lower = fileName.toLowerCase();
    return textExtensions.any((ext) => lower.endsWith(ext));
  }

  Map<String, dynamic> toJson() {
    return {
      'fileName': fileName,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'dataBase64': dataBase64,
    };
  }

  factory AiChatAttachment.fromJson(Map<String, dynamic> json) {
    return AiChatAttachment(
      fileName: json['fileName'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      dataBase64: json['dataBase64'] as String? ?? '',
    );
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
class OpenAiReasoningEffort {
  static const String low = 'low';
  static const String medium = 'medium';
  static const String high = 'high';
  static const String xhigh = 'xhigh';
  static const String defaultEffort = medium;
  static const List<String> values = [low, medium, high, xhigh];

  static String normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return values.contains(normalized) ? normalized! : defaultEffort;
  }

  static String label(String value) {
    switch (normalize(value)) {
      case low:
        return 'Low';
      case high:
        return 'High';
      case xhigh:
        return 'Extra high';
      case medium:
      default:
        return 'Medium';
    }
  }
}

bool isDeepSeekModelId(String model) {
  return model.trim().toLowerCase().contains('deepseek');
}

bool supportsOpenAiReasoningEffort(String model) {
  final normalized = model.trim().toLowerCase();
  return normalized.startsWith('gpt-5') ||
      normalized.startsWith('o1') ||
      normalized.startsWith('o3') ||
      normalized.startsWith('o4');
}

String maskAiApiKey(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.length <= 4) return trimmed;
  if (trimmed.length <= 6) {
    final prefix = trimmed.substring(0, 4);
    final suffix = trimmed.substring(trimmed.length - 2);
    final hiddenCount = trimmed.length - prefix.length - suffix.length;
    return '$prefix${'*' * hiddenCount}$suffix';
  }
  final prefix = trimmed.substring(0, 4);
  final suffix = trimmed.substring(trimmed.length - 2);
  return '$prefix${'*' * (trimmed.length - 6)}$suffix';
}

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
  final List<AiChatAttachment> attachments;
  final int? reasoningTokens;

  const AiChatMessageRecord({
    required this.role,
    required this.text,
    this.contextText,
    this.attachments = const [],
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
    List<AiChatAttachment>? attachments,
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
      attachments: attachments ?? this.attachments,
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
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toJson()).toList(),
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
      attachments: ((json['attachments'] as List<dynamic>?) ?? const [])
          .map(
              (item) => AiChatAttachment.fromJson(item as Map<String, dynamic>))
          .toList(),
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
  final String id;
  final String kind;
  final String title;
  final String content;
  final DateTime createdAt;

  const AiMessageTrace({
    required this.id,
    required this.kind,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  factory AiMessageTrace.create({
    required String kind,
    required String title,
    required String content,
    DateTime? createdAt,
  }) {
    return AiMessageTrace(
      id: _traceUuid.v4(),
      kind: kind,
      title: title,
      content: content,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind,
      'title': title,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AiMessageTrace.fromJson(Map<String, dynamic> json) {
    final rawId = (json['id'] as String?)?.trim();
    return AiMessageTrace(
      id: rawId?.isNotEmpty == true ? rawId! : _traceUuid.v4(),
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
