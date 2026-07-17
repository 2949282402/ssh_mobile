import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/database/app_database.dart' as db;
import '../data/database/migrations.dart';
import '../features/ai_chat/models/agent_trace_event.dart';
import '../features/connection/models/connection.dart';
import '../features/playbook/models/playbook.dart';
import '../utils/skill_frontmatter.dart';
import 'agent_model_profile.dart';
import 'app_log_service.dart';
import '../core/services/data_protection_service.dart';
import 'connection_target_binding.dart';
import 'multi_agent_coordinator.dart';
import 'llm_provider/llm_api_format.dart';

part 'storage/storage_models_ai_settings.dart';
part 'storage/storage_models_ai_resources.dart';
part 'storage/storage_models_ai_chat.dart';
part 'storage/storage_repositories.dart';
part 'storage/storage_models_terminal.dart';
part 'storage/storage_models_sftp.dart';
part 'storage/settings_ops.dart';
part 'storage/connection_ops.dart';
part 'storage/ai_chat_ops.dart';
part 'storage/ai_skill_ops.dart';
part 'storage/terminal_ops.dart';
part 'storage/playbook_ops.dart';
part 'storage/backup_ops.dart';
part 'storage/buffered_write_ops.dart';
part 'storage/drift_ops.dart';
part '../data/repositories/drift_ai_chat_repository.dart';
part '../data/repositories/drift_agent_metrics_repository.dart';
part '../data/repositories/drift_agent_trace_repository.dart';
part '../data/repositories/drift_terminal_history_repository.dart';
part '../data/repositories/drift_playbook_repository.dart';
part '../data/repositories/drift_sftp_history_repository.dart';

class StorageService extends ChangeNotifier
    implements
        ConnectionRepository,
        AiSettingsRepository,
        AiChatRepository,
        AiSkillRepository,
        AgentRunMetricsRepository,
        AgentTraceRepository,
        TerminalHistoryRepository,
        PlaybookRepository,
        SftpPathHistoryRepository,
        AppBackupRepository {
  final db.AppDatabase? _providedDatabase;
  Completer<void>? _aiSettingsOperation;
  Completer<void>? _aiSkillOperation;
  Completer<void>? _connectionOperation;
  Completer<void>? _playbookOperation;
  final Object _aiSkillOperationOwner = Object();
  final Object _playbookOperationOwner = Object();
  static final Object _aiSkillOperationZoneKey = Object();
  static final Object _playbookOperationZoneKey = Object();

  StorageService({db.AppDatabase? database}) : _providedDatabase = database;

  Future<T> _runExclusiveAiSettingsOperation<T>(
    Future<T> Function() operation,
  ) async {
    while (true) {
      final active = _aiSettingsOperation;
      if (active != null) {
        await active.future;
        continue;
      }
      final ticket = Completer<void>();
      _aiSettingsOperation = ticket;
      try {
        return await operation();
      } finally {
        if (identical(_aiSettingsOperation, ticket)) {
          _aiSettingsOperation = null;
        }
        ticket.complete();
      }
    }
  }

  Future<T> _runExclusiveConnectionOperation<T>(
    Future<T> Function() operation,
  ) async {
    while (true) {
      final active = _connectionOperation;
      if (active != null) {
        await active.future;
        continue;
      }
      final ticket = Completer<void>();
      _connectionOperation = ticket;
      try {
        return await operation();
      } finally {
        if (identical(_connectionOperation, ticket)) {
          _connectionOperation = null;
        }
        ticket.complete();
      }
    }
  }

  Future<T> _runExclusiveAiSkillOperation<T>(
    Future<T> Function() operation,
  ) async {
    if (identical(
      Zone.current[_aiSkillOperationZoneKey],
      _aiSkillOperationOwner,
    )) {
      return operation();
    }
    while (true) {
      final active = _aiSkillOperation;
      if (active != null) {
        await active.future;
        continue;
      }
      final ticket = Completer<void>();
      _aiSkillOperation = ticket;
      try {
        return await runZoned(
          operation,
          zoneValues: {_aiSkillOperationZoneKey: _aiSkillOperationOwner},
        );
      } finally {
        if (identical(_aiSkillOperation, ticket)) {
          _aiSkillOperation = null;
        }
        ticket.complete();
      }
    }
  }

  Future<T> _runExclusivePlaybookOperation<T>(
    Future<T> Function() operation,
  ) async {
    if (identical(
      Zone.current[_playbookOperationZoneKey],
      _playbookOperationOwner,
    )) {
      return operation();
    }
    while (true) {
      final active = _playbookOperation;
      if (active != null) {
        await active.future;
        continue;
      }
      final ticket = Completer<void>();
      _playbookOperation = ticket;
      try {
        return await runZoned(
          operation,
          zoneValues: {_playbookOperationZoneKey: _playbookOperationOwner},
        );
      } finally {
        if (identical(_playbookOperation, ticket)) {
          _playbookOperation = null;
        }
        ticket.complete();
      }
    }
  }

  @override
  Future<void> addConnection(ConnectionConfig config) =>
      _runExclusiveConnectionOperation(
        () => ConnectionOps(this).addConnection(config),
      );

  @override
  Future<void> updateConnection(ConnectionConfig config) =>
      _runExclusiveConnectionOperation(
        () => ConnectionOps(this).updateConnection(config),
      );

  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) => _runExclusiveConnectionOperation(
    () => ConnectionOps(this).trustHostKey(
      connectionId,
      algorithm: algorithm,
      fingerprint: fingerprint,
      trustedAt: trustedAt,
    ),
  );

  @override
  Future<void> deleteConnection(String id) => _runExclusiveConnectionOperation(
    () => ConnectionOps(this).deleteConnection(id),
  );

  @override
  Future<void> deleteConnections(List<String> ids) =>
      _runExclusiveConnectionOperation(
        () => ConnectionOps(this).deleteConnections(List<String>.of(ids)),
      );

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) =>
      _runExclusiveConnectionOperation(
        () => ConnectionOps(this).reorderConnections(oldIndex, newIndex),
      );

  /// Captures immutable, non-secret connection targets without an async gap.
  Map<String, ConnectionTargetBinding> captureConnectionTargetBindings(
    Iterable<String> connectionIds,
  ) {
    final bindings = <String, ConnectionTargetBinding>{};
    for (final id in connectionIds.toSet()) {
      final config = ConnectionOps(this).getConnection(id);
      if (config != null) {
        bindings[id] = ConnectionTargetBinding.fromConfig(config);
      }
    }
    return Map<String, ConnectionTargetBinding>.unmodifiable(bindings);
  }

  /// Atomically validates a target binding and pairs it with its credentials.
  ///
  /// The returned target is short-lived and must never be persisted or logged.
  Future<ConnectionRuntimeTarget?> resolveConnectionTarget(
    ConnectionTargetBinding binding,
  ) {
    return _runExclusiveConnectionOperation(() async {
      _ensureInitialized();
      final current = ConnectionOps(this).getConnection(binding.id);
      if (!binding.matches(current)) return null;

      final configSnapshot = ConnectionConfig.fromJson(
        Map<String, dynamic>.from(current!.toJson()),
      );
      final password = await ConnectionOps(this).getPassword(binding.id);
      final privateKey = await ConnectionOps(this).getPrivateKey(binding.id);
      return ConnectionRuntimeTarget(
        binding,
        configSnapshot,
        password,
        privateKey,
      );
    });
  }

  /// Updates a saved connection only while its approved target still matches.
  Future<bool> updateConnectionIfMatches(
    ConnectionTargetBinding binding,
    ConnectionConfig next,
  ) {
    if (next.id != binding.id) {
      throw ArgumentError.value(
        next.id,
        'next',
        'Connection id must match the target binding.',
      );
    }
    return _runExclusiveConnectionOperation(() async {
      final current = ConnectionOps(this).getConnection(binding.id);
      if (!binding.matches(current)) return false;
      await ConnectionOps(this).updateConnection(next);
      return true;
    });
  }

  /// Atomically replaces a connection only if every persisted non-secret
  /// field still matches the snapshot shown for approval.
  Future<bool> updateConnectionFromSnapshotIfUnchanged({
    required ConnectionConfig expected,
    required ConnectionConfig next,
  }) {
    if (next.id != expected.id) {
      throw ArgumentError.value(
        next.id,
        'next',
        'Connection id must match the expected snapshot.',
      );
    }
    return _runExclusiveConnectionOperation(() async {
      final current = ConnectionOps(this).getConnection(expected.id);
      if (current == null ||
          jsonEncode(current.toJson()) != jsonEncode(expected.toJson())) {
        return false;
      }
      final password = await ConnectionOps(this).getPassword(expected.id);
      final privateKey = await ConnectionOps(this).getPrivateKey(expected.id);
      final persisted = ConnectionConfig.fromJson(next.toJson())
        ..password = password
        ..privateKey = privateKey;
      await ConnectionOps(this).updateConnection(persisted);
      return true;
    });
  }

  /// Deletes a saved connection only while its approved target still matches.
  Future<bool> deleteConnectionIfMatches(ConnectionTargetBinding binding) {
    return _runExclusiveConnectionOperation(() async {
      final current = ConnectionOps(this).getConnection(binding.id);
      if (!binding.matches(current)) return false;
      await ConnectionOps(this).deleteConnection(binding.id);
      return true;
    });
  }

  @override
  ConnectionConfig? getConnection(String id) =>
      ConnectionOps(this).getConnection(id);

  @override
  Future<String?> getPassword(String id) => ConnectionOps(this).getPassword(id);

  @override
  Future<String?> getPrivateKey(String id) =>
      ConnectionOps(this).getPrivateKey(id);

  @override
  Future<AiConnectionSettings> loadAiConnectionSettings() =>
      _runExclusiveAiSettingsOperation(
        () => SettingsOps(this).loadAiConnectionSettings(),
      );

  @override
  Future<AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot() =>
      _runExclusiveAiSettingsOperation(() async {
        final settings = await SettingsOps(this).loadAiConnectionSettings();
        final apiKey = (await SettingsOps(this).getAiApiKey())?.trim() ?? '';
        final quarkApiKey =
            (await SettingsOps(this).getQuarkApiKey())?.trim() ?? '';
        final aliyunApiKey =
            (await SettingsOps(this).getAliyunApiKey())?.trim() ?? '';
        return AiRuntimeConnectionSnapshot(
          settings: settings,
          apiKey: apiKey,
          quarkApiKey: quarkApiKey,
          aliyunApiKey: aliyunApiKey,
        );
      });

  @override
  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    String? helperModel,
    String? auditModel,
    String? modelFallbackPolicy,
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
    bool? postToolReviewEnabled,
    int? toolCallBudget,
    String? agentLoopMode,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    String? apiKey,
    String? selectedApiKeyId,
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    LlmApiFormat? apiFormat,
  }) => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).saveAiConnectionSettings(
      baseUrl: baseUrl,
      model: model,
      helperModel: helperModel,
      auditModel: auditModel,
      modelFallbackPolicy: modelFallbackPolicy,
      contextWindowTokens: contextWindowTokens,
      timeoutSeconds: timeoutSeconds,
      deepSeekThinkingEnabled: deepSeekThinkingEnabled,
      deepSeekReasoningEffort: deepSeekReasoningEffort,
      openAiReasoningEffort: openAiReasoningEffort,
      webSearchEnabled: webSearchEnabled,
      webSearchMaxResults: webSearchMaxResults,
      webSearchEngine: webSearchEngine,
      multiAgentEnabled: multiAgentEnabled,
      multiAgentMaxAgents: multiAgentMaxAgents,
      postToolReviewEnabled: postToolReviewEnabled,
      toolCallBudget: toolCallBudget,
      agentLoopMode: agentLoopMode,
      maxImageSizeBytes: maxImageSizeBytes,
      maxFileSizeBytes: maxFileSizeBytes,
      apiKey: apiKey,
      selectedApiKeyId: selectedApiKeyId,
      clearApiKey: clearApiKey,
      quarkSearchEndpoint: quarkSearchEndpoint,
      quarkApiKey: quarkApiKey,
      clearQuarkApiKey: clearQuarkApiKey,
      useCustomPrompts: useCustomPrompts,
      customSystemPrompt: customSystemPrompt,
      customPlannerPrompt: customPlannerPrompt,
      customOperatorPrompt: customOperatorPrompt,
      customExplorePrompt: customExplorePrompt,
      customReviewerPrompt: customReviewerPrompt,
      customSummarizerPrompt: customSummarizerPrompt,
      customCoordinatorPrompt: customCoordinatorPrompt,
      apiFormat: apiFormat,
    ),
  );

  @override
  Future<List<String>> loadCachedAiModels({String? baseUrl}) =>
      SettingsOps(this).loadCachedAiModels(baseUrl: baseUrl);

  @override
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) =>
      SettingsOps(this).removeAiBaseUrlHistoryEntry(baseUrl);

  @override
  Future<void> removeAiApiKeyHistoryEntry(String id) =>
      _runExclusiveAiSettingsOperation(
        () => SettingsOps(this).removeAiApiKeyHistoryEntry(id),
      );

  @override
  Future<List<AiApiKeyHistoryEntry>> loadAiApiKeyHistory() =>
      _runExclusiveAiSettingsOperation(
        () => SettingsOps(this).loadAiApiKeyHistory(),
      );

  @override
  Future<String?> getAiApiKeyById(String id) =>
      _runExclusiveAiSettingsOperation(
        () => SettingsOps(this).getAiApiKeyById(id),
      );

  @override
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required Iterable<String> models,
  }) => SettingsOps(this).saveCachedAiModels(baseUrl: baseUrl, models: models);

  @override
  Future<void> clearCachedAiModels({String? baseUrl}) =>
      SettingsOps(this).clearCachedAiModels(baseUrl: baseUrl);

  @override
  Future<int> getAiRequestTimeoutSeconds() =>
      SettingsOps(this).getAiRequestTimeoutSeconds();

  @override
  Future<void> selectAiApiKey(String id) => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).selectAiApiKey(id),
  );

  @override
  Future<void> deleteAiApiKey(String id) => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).deleteAiApiKey(id),
  );

  @override
  Future<String?> getAiApiKey() =>
      _runExclusiveAiSettingsOperation(() => SettingsOps(this).getAiApiKey());

  @override
  Future<String?> getQuarkApiKey() => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).getQuarkApiKey(),
  );

  @override
  Future<void> saveQuarkApiKey(String key) => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).saveQuarkApiKey(key),
  );

  @override
  Future<String?> getAliyunApiKey() => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).getAliyunApiKey(),
  );

  @override
  Future<void> saveAliyunApiKey(String key) => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).saveAliyunApiKey(key),
  );

  @override
  Future<String?> getSelectedAiApiKeyId() => _runExclusiveAiSettingsOperation(
    () => SettingsOps(this).getSelectedAiApiKeyId(),
  );

  @override
  Future<List<String>> loadAiBaseUrlHistory() =>
      SettingsOps(this).loadAiBaseUrlHistory();

  @override
  Future<void> setSecretCacheEnabled(bool enabled) =>
      SettingsOps(this).setSecretCacheEnabled(enabled);

  @override
  Future<void> setSecretCacheTtl(Duration ttl) =>
      SettingsOps(this).setSecretCacheTtl(ttl);

  @override
  void clearSecretCache() => SettingsOps(this).clearSecretCache();

  static const _connectionsKey = 'ssh_connections';
  static const _powerGuideSeenKey = 'power_guide_seen';
  static const _restorableTmuxSessionsKey = 'restorable_tmux_sessions';
  static const _terminalHistoryRecordsKey = 'terminal_history_records';
  static const _aiBaseUrlKey = 'ai_base_url';
  static const _aiApiFormatKey = 'ai_api_format';
  static const _aiBaseUrlHistoryKey = 'ai_base_url_history';
  static const _aiModelKey = 'ai_model';
  static const _aiHelperModelKey = 'ai_helper_model';
  static const _aiAuditModelKey = 'ai_audit_model';
  static const _aiModelFallbackPolicyKey = 'ai_model_fallback_policy';
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
  static const _aiPostToolReviewEnabledKey = 'ai_post_tool_review_enabled';
  static const _aiMultiAgentMaxAgentsKey = 'ai_multi_agent_max_agents';
  static const _aiToolCallBudgetKey = 'ai_tool_call_budget';
  static const _aiAgentLoopModeKey = 'ai_agent_loop_mode';
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
  static const _agentRunMetricsKey = 'agent_run_metrics';
  static const _playbooksKey = 'custom_playbooks';
  static const _driftAiChatsMigratedKey = 'drift_ai_chats_migrated_v1';
  static const _driftAgentMetricsMigratedKey =
      'drift_agent_metrics_migrated_v1';
  static const _driftTerminalHistoryMigratedKey =
      'drift_terminal_history_migrated_v1';
  static const _driftPlaybooksMigratedKey = 'drift_playbooks_migrated_v1';
  static const _driftSensitiveFieldsEncryptedKey =
      'drift_sensitive_fields_encrypted_v1';
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
  db.AppDatabase? _database;
  bool _ownsDatabase = false;
  bool _driftReady = false;
  bool _driftAiChatsActive = false;
  bool _driftAgentMetricsActive = false;
  bool _driftAgentTraceActive = false;
  bool _driftTerminalHistoryActive = false;
  bool _driftPlaybooksActive = false;
  bool _driftSftpHistoryActive = false;

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
  List<AgentRunMetrics>? _agentRunMetricsCache;
  final Map<String, List<AgentTraceEvent>> _agentTraceEventsCache = {};
  List<Playbook>? _playbooksCache;
  List<RestorableTmuxSession>? _restorableTmuxSessionsCache;
  List<TerminalHistoryRecord>? _terminalHistoryRecordsCache;
  bool _initialized = false;
  final Completer<void> _initCompleter = Completer<void>();
  Future<void> get initFuture => _initCompleter.future;
  final Completer<void> _driftInitCompleter = Completer<void>();
  Future<void> get driftInitFuture => _driftInitCompleter.future;

  bool _initCalled = false;

  Future<T> _executeDrift<T>(Future<T> Function() action) async {
    if (_initCalled) {
      await driftInitFuture;
    }
    return action();
  }

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

  @override
  List<ConnectionConfig> get connections => _connectionsView;
  @override
  bool get isSecretCacheEnabled => _secretCacheEnabled;
  @override
  Duration get secretCacheTtl => _secretCacheTtl;
  int get secretCacheTtlMinutes => _secretCacheTtl.inMinutes;
  List<int> get secretCacheTtlOptionsMinutes =>
      List.unmodifiable(_memorySecretTtlOptionsMinutes);
  bool get initialized => _initialized;
  bool get powerGuideSeen => _powerGuideSeen;

  Future<void> init() async {
    _initCalled = true;
    try {
      _prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
      _powerGuideSeen = _prefs?.getBool(_powerGuideSeenKey) ?? false;
      await _loadSecretCacheSettings();
      await _loadConnections();
    } catch (e) {
      AppLogService.instance.error(
        'Failed to initialize storage service preferences',
        error: e,
      );
      _connections = [];
      _refreshConnectionsView();
      _powerGuideSeen = false;
    } finally {
      _initialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      notifyListeners();

      if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
        await _initializeDriftStorage();
      } else {
        // Asynchronously initialize Drift database in the background to not block cold start
        unawaited(
          _initializeDriftStorage().catchError((e) {
            AppLogService.instance.error(
              'Asynchronous Drift initialization failed',
              error: e,
            );
          }),
        );
      }
    }
  }

  @override
  Future<List<AiChatRecord>> loadAiChats() =>
      _executeDrift(() => _loadAiChats());

  @override
  Future<void> saveAiChat(AiChatRecord chat) =>
      _executeDrift(() => _saveAiChat(chat));

  @override
  Future<void> deleteAiChat(String id) =>
      _executeDrift(() => _deleteAiChat(id));

  @override
  Future<List<AiSkillRecord>> loadAiSkills() =>
      _runExclusiveAiSkillOperation(_loadAiSkills);

  @override
  Future<void> saveAiSkill(AiSkillRecord skill) =>
      _runExclusiveAiSkillOperation(() => _saveAiSkill(skill));

  @override
  Future<void> deleteAiSkill(String id) =>
      _runExclusiveAiSkillOperation(() => _deleteAiSkill(id));

  /// Compare-and-swap update used when a caller approved a specific skill.
  Future<bool> saveAiSkillIfUnchanged(
    AiSkillRecord expected,
    AiSkillRecord next,
  ) {
    if (next.id != expected.id) {
      throw ArgumentError.value(
        next.id,
        'next',
        'AI skill id must match the expected record.',
      );
    }
    return _runExclusiveAiSkillOperation(() async {
      final skills = await _loadAiSkills();
      AiSkillRecord? current;
      for (final skill in skills) {
        if (skill.id == expected.id) {
          current = skill;
          break;
        }
      }
      if (current == null ||
          jsonEncode(current.toJson()) != jsonEncode(expected.toJson())) {
        return false;
      }
      await _saveAiSkill(next);
      return true;
    });
  }

  @override
  Future<List<AgentRunMetrics>> loadAgentRunMetrics() =>
      _executeDrift(() => _loadAgentRunMetrics());

  @override
  Future<void> saveAgentRunMetrics(AgentRunMetrics metrics) =>
      _executeDrift(() => _saveAgentRunMetrics(metrics));

  @override
  Future<List<AgentTraceEvent>> loadAgentTraceEvents(String runId) =>
      _executeDrift(() => _loadAgentTraceEvents(runId));

  @override
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => _executeDrift(
    () => _loadRecentAgentTraceRunIdsForChat(chatId, limit: limit),
  );

  @override
  Future<void> saveAgentTraceEvent(AgentTraceEvent event) =>
      _executeDrift(() => _saveAgentTraceEvent(event));

  @override
  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events) =>
      _executeDrift(() => _saveAgentTraceEvents(events));

  @override
  Future<void> deleteAgentTraceEvents(String runId) =>
      _executeDrift(() => _deleteAgentTraceEvents(runId));

  @override
  Future<List<Playbook>> loadPlaybooks() => _runExclusivePlaybookOperation(
    () => _executeDrift(() => _loadPlaybooks()),
  );

  @override
  Future<void> savePlaybook(Playbook playbook) =>
      _runExclusivePlaybookOperation(
        () => _executeDrift(() => _savePlaybook(playbook)),
      );

  @override
  Future<void> deletePlaybook(String id) => _runExclusivePlaybookOperation(
    () => _executeDrift(() => _deletePlaybook(id)),
  );

  /// Persists execution state only while the approved commands are unchanged.
  Future<bool> savePlaybookIfActionUnchanged({
    required String playbookId,
    required String expectedActionFingerprint,
    required Playbook playbook,
  }) {
    if (playbook.id != playbookId) {
      throw ArgumentError.value(
        playbook.id,
        'playbook',
        'Playbook id must match playbookId.',
      );
    }
    return _runExclusivePlaybookOperation(
      () => _executeDrift(() async {
        final playbooks = await _loadPlaybooks();
        Playbook? current;
        for (final candidate in playbooks) {
          if (candidate.id == playbookId) {
            current = candidate;
            break;
          }
        }
        if (current == null ||
            _playbookActionFingerprintForStorage(current) !=
                expectedActionFingerprint) {
          return false;
        }
        await _savePlaybook(playbook);
        return true;
      }),
    );
  }

  @override
  Future<void> recordVisitedPath(String connectionId, String path) =>
      _executeDrift(() => _recordSftpVisitedPath(connectionId, path));

  @override
  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) => _executeDrift(() => _loadSftpRecentPaths(connectionId, limit: limit));

  @override
  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) => _executeDrift(() => _addSftpFavoritePath(connectionId, path, name));

  @override
  Future<void> removeFavoritePath(String id) =>
      _executeDrift(() => _removeSftpFavoritePath(id));

  @override
  Future<void> renameFavoritePath(String id, String name) =>
      _executeDrift(() => _renameSftpFavoritePath(id, name));

  @override
  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId) =>
      _executeDrift(() => _loadSftpFavoritePaths(connectionId));

  @override
  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) => _executeDrift(() => _findSftpFavoritePath(connectionId, path));

  @override
  Future<String> exportAppDataJson() =>
      _executeDrift(() => _exportAppDataJson());

  @override
  Future<void> importAppDataJson(String jsonText) async {
    await driftInitFuture;
    await _importAppDataJson(jsonText);
    notifyListeners();
  }

  @override
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() =>
      _executeDrift(() => _loadTerminalHistoryRecords());

  @override
  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) =>
      _executeDrift(() => _saveTerminalHistoryRecord(record));

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) =>
      _executeDrift(() => _removeTerminalHistoryRecord(sessionId));

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

  String _playbookActionFingerprintForStorage(Playbook playbook) {
    return jsonEncode({
      'id': playbook.id,
      'name': playbook.name,
      'description': playbook.description,
      'steps': playbook.steps
          .map(
            (step) => {
              'id': step.id,
              'name': step.name,
              'command': step.command,
              'description': step.description,
              'expectedOutcomeRegex': step.expectedOutcomeRegex,
            },
          )
          .toList(growable: false),
    });
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final pending in _pendingProtectedPrefWrites.values) {
      pending.timer?.cancel();
    }
    unawaited(flushPendingWrites());
    if (_ownsDatabase) {
      unawaited(_database?.close());
    }
    super.dispose();
  }
}
