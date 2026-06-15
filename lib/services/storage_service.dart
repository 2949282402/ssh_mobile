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

part 'storage/storage_models.dart';
part 'storage/settings_ops.dart';
part 'storage/connection_ops.dart';
part 'storage/ai_chat_ops.dart';
part 'storage/terminal_ops.dart';
part 'storage/playbook_ops.dart';
part 'storage/backup_ops.dart';
part 'storage/buffered_write_ops.dart';

const Uuid _traceUuid = Uuid();

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
  static const _aiToolCallBudgetKey = 'ai_tool_call_budget';
  static const _aiMaxImageSizeBytesKey = 'ai_max_image_size_bytes';
  static const _aiMaxFileSizeBytesKey = 'ai_max_file_size_bytes';
  static const _aiUseCustomPromptsKey = 'ai_use_custom_prompts';
  static const _aiCustomSystemPromptKey = 'ai_custom_system_prompt';
  static const _aiCustomPlannerPromptKey = 'ai_custom_planner_prompt';
  static const _aiCustomOperatorPromptKey = 'ai_custom_operator_prompt';
  static const _aiCustomExplorePromptKey = 'ai_custom_explore_prompt';
  static const _aiCustomReviewerPromptKey = 'ai_custom_reviewer_prompt';
  static const _aiCustomSummarizerPromptKey = 'ai_custom_summarizer_prompt';
  static const _aiCustomCoordinatorPromptKey = 'ai_custom_coordinator_prompt';
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
  static const _protectedPrefWriteDebounce = Duration(milliseconds: 700);
  static const _passwordSecretKeyPrefix = 'pwd_';
  static const _privateKeySecretKeyPrefix = 'key_';
  static const _memoryAiApiKeyCacheKey = 'ai_api_key_cached';
  static const _memorySecretTtlOptionsMinutes = [1, 5, 15, 30, 60];

  SharedPreferences? _prefs;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  final DataProtectionService _dataProtection = DataProtectionService.instance;

  Future<String?> _readSecure(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Secure storage read failed',
        error: e,
        stackTrace: stackTrace,
        details: 'key=$key',
      );
      rethrow;
    }
  }

  Future<void> _writeSecure(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Secure storage write failed',
        error: e,
        stackTrace: stackTrace,
        details: 'key=$key',
      );
      rethrow;
    }
  }

  Future<void> _deleteSecure(String key) async {
    try {
      await _secureStorage.delete(key: key);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Secure storage delete failed',
        error: e,
        stackTrace: stackTrace,
        details: 'key=$key',
      );
      rethrow;
    }
  }

  final Map<String, _PendingProtectedPrefWrite> _pendingProtectedPrefWrites =
      {};

  List<ConnectionConfig> _connections = [];
  List<ConnectionConfig> _connectionsView = const [];
  List<AiChatRecord>? _aiChatsCache;
  List<AiSkillRecord>? _aiSkillsCache;
  List<Playbook>? _playbooksCache;
  List<RestorableTmuxSession>? _restorableTmuxSessionsCache;
  List<TerminalHistoryRecord>? _terminalHistoryRecordsCache;
  bool _initialized = false;
  final Completer<void> _initCompleter = Completer<void>();
  Future<void> get initFuture => _initCompleter.future;
  bool _powerGuideSeen = false;
  bool _secretCacheEnabled = true;
  Duration _secretCacheTtl = const Duration(minutes: 15);
  final Map<String, _MemorySecret> _secretCache = {};

  final List<VoidCallback> _onImportCallbacks = [];

  void registerOnImportCallback(VoidCallback callback) {
    addOnImportCallback(callback);
  }

  void unregisterOnImportCallback(VoidCallback callback) {
    removeOnImportCallback(callback);
  }

  void notifyStorageListeners() {
    notifyListeners();
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
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      notifyListeners();
    }
  }

  @override
  Future<List<AiChatRecord>> loadAiChats() => _loadAiChats();

  @override
  Future<void> saveAiChat(AiChatRecord chat) => _saveAiChat(chat);

  @override
  Future<void> deleteAiChat(String id) => _deleteAiChat(id);

  @override
  Future<List<AiSkillRecord>> loadAiSkills() => _loadAiSkills();

  @override
  Future<void> saveAiSkill(AiSkillRecord skill) => _saveAiSkill(skill);

  @override
  Future<void> deleteAiSkill(String id) => _deleteAiSkill(id);

  @override
  Future<List<Playbook>> loadPlaybooks() => _loadPlaybooks();

  @override
  Future<void> savePlaybook(Playbook playbook) => _savePlaybook(playbook);

  @override
  Future<void> deletePlaybook(String id) => _deletePlaybook(id);

  @override
  Future<String> exportAppDataJson() => _exportAppDataJson();

  @override
  Future<void> importAppDataJson(String jsonText) async {
    await _importAppDataJson(jsonText);
    notifyListeners();
  }

  @override
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() =>
      _loadTerminalHistoryRecords();

  @override
  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) =>
      _saveTerminalHistoryRecord(record);

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) =>
      _removeTerminalHistoryRecord(sessionId);

  Future<void> markPowerGuideSeen() async {
    if (!_initialized) return;
    _powerGuideSeen = true;
    await _prefs?.setBool(_powerGuideSeenKey, true);
    notifyListeners();
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
