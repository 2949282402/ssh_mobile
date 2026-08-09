import 'dart:async';
import 'dart:convert';

import 'package:connection_core/connection_core.dart';
import 'package:feature_ai/feature_ai.dart';
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_playbook/feature_playbook.dart';
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:uuid/uuid.dart';

import '../core/services/data_protection_service.dart';
import '../services/app_log_service.dart';
import '../services/terminal_session_metadata_store.dart';

part 'ai_storage/ai_settings_ops.dart';
part 'ai_storage/ai_skill_ops.dart';
part 'ai_storage/app_backup_ops.dart';
part 'ai_storage/protected_pref_write_ops.dart';
part 'ai_storage/ai_storage_helpers.dart';

const Uuid _traceUuid = Uuid();

/// App Shell 对 AI 设置、技能和 AI 数据库的最小组合适配器。
///
/// 该类只编排注入的 Core/Feature Repository，不再拥有 AppDatabase，也不
/// 负责 SFTP、Playbook、Connection 等其他模块的底层实现。ai.db 由
/// [feature_ai.AiModule] 持有；本适配器只在首次访问聊天或 trace 时请求它。
final class AppAiStorageAdapter extends ChangeNotifier
    implements feature_ai.AiStoragePort {
  /// 创建 AI 存储适配器。
  AppAiStorageAdapter({
    required ConnectionRepository connectionRepository,
    required CredentialRepository credentialRepository,
    required HostKeyRepository hostKeyRepository,
    required feature_playbook.PlaybookRepository playbookRepository,
    required feature_ai.AiModule aiModule,
    required TerminalSessionMetadataStore terminalMetadataStore,
    Future<feature_ai.AiRepository> Function()? aiRepositoryLoader,
    @visibleForTesting this.initializationCheckpoint,
  }) : _connectionRepository = connectionRepository,
       _credentialRepository = credentialRepository,
       _hostKeyRepository = hostKeyRepository,
       _playbookRepository = playbookRepository,
       _aiModule = aiModule,
       _terminalMetadataStore = terminalMetadataStore,
       _aiRepositoryLoader = aiRepositoryLoader;

  /// 测试可注入的初始化检查点，不改变生产初始化顺序。
  @visibleForTesting
  final Future<void> Function()? initializationCheckpoint;

  final ConnectionRepository _connectionRepository;
  final CredentialRepository _credentialRepository;
  final HostKeyRepository _hostKeyRepository;
  final feature_playbook.PlaybookRepository _playbookRepository;
  final feature_ai.AiModule _aiModule;
  final TerminalSessionMetadataStore _terminalMetadataStore;
  Future<feature_ai.AiRepository> Function()? _aiRepositoryLoader;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  final DataProtectionService _dataProtection = DataProtectionService.instance;
  final Completer<void> _initCompleter = Completer<void>();
  final Object _aiSkillOperationOwner = Object();
  static final Object _aiSkillOperationZoneKey = Object();

  SharedPreferences? _prefs;
  Future<void>? _initializationFuture;
  Future<feature_ai.AiRepository>? _aiRepositoryFuture;
  Future<void>? _aiSkillOperation;
  bool _initialized = false;
  bool _disposed = false;
  bool _notifierDisposed = false;
  bool _powerGuideSeen = false;
  bool _secretCacheEnabled = true;
  Duration _secretCacheTtl = _defaultSecretCacheTtl;
  final Map<String, _MemorySecret> _secretCache = {};
  List<feature_ai.AiSkillRecord>? _aiSkillsCache;
  final Map<String, _PendingProtectedPrefWrite> _pendingProtectedPrefWrites =
      {};
  final List<FutureOr<void> Function()> _onImportCallbacks = [];

  static const _powerGuideSeenKey = 'power_guide_seen';
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
  static const _aiSkillsKey = 'ai_skills';
  static const _secretCacheEnabledKey = 'secret_cache_enabled';
  static const _secretCacheTtlSecondsKey = 'secret_cache_ttl_seconds';
  static const _defaultSecretCacheTtl = Duration(minutes: 15);
  static const _protectedPrefWriteDebounce = Duration(milliseconds: 700);
  static const _passwordSecretKeyPrefix = 'pwd_';
  static const _privateKeySecretKeyPrefix = 'key_';
  static const _memoryAiApiKeyCacheKey = 'ai_api_key_cached';
  static const _memorySecretTtlOptionsMinutes = [1, 5, 15, 30, 60];

  /// 当前初始化 Future，供 App Bootstrap 和测试等待。
  Future<void> get initFuture => _initCompleter.future;

  /// 是否完成 SharedPreferences 初始化。
  bool get initialized => _initialized;

  /// 旧启动引导所需的只读状态；新代码应从 AppSettings 读取。
  bool get powerGuideSeen => _powerGuideSeen;

  /// 供设置页面展示的 TTL 选项。
  List<int> get secretCacheTtlOptionsMinutes =>
      List.unmodifiable(_memorySecretTtlOptionsMinutes);

  /// 启动偏好初始化，不打开 ai.db。
  Future<void> init() => _initializationFuture ??= _initialize();

  /// 与 Core Repository 使用相同的命名，方便测试和生命周期装配。
  Future<void> initialize() => init();

  Future<void> _initialize() async {
    try {
      await initializationCheckpoint?.call();
      _prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
      _powerGuideSeen = _prefs!.getBool(_powerGuideSeenKey) ?? false;
      await _loadSecretCacheSettings();
      await _connectionRepository.initialize();
      await _terminalMetadataStore.initialize();
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'AI storage preferences initialization failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      _initialized = true;
      if (!_initCompleter.isCompleted) _initCompleter.complete();
      notifyStorageListeners();
    }
  }

  @override
  List<ConnectionConfig> get connections => _connectionRepository.connections;

  @override
  ConnectionConfig? getConnection(String id) =>
      _connectionRepository.getConnection(id);

  /// 供仍处于 App Shell 的编辑器使用的连接操作。
  Future<void> addConnection(ConnectionConfig config) async {
    await init();
    await _connectionRepository.addConnection(config);
    await _credentialRepository.saveCredentials(
      connectionId: config.id,
      password: config.password,
      privateKey: config.privateKey,
    );
    notifyStorageListeners();
  }

  /// 供仍处于 App Shell 的编辑器使用的连接操作。
  Future<void> updateConnection(ConnectionConfig config) async {
    await init();
    // Connection Core 不再把密钥字段写入非敏感快照；兼容编辑入口传入空
    // 字段时必须保留现有凭据，只有显式传入空字符串才表示清除凭据。
    final password =
        config.password ?? await _credentialRepository.getPassword(config.id);
    final privateKey =
        config.privateKey ??
        await _credentialRepository.getPrivateKey(config.id);
    await _connectionRepository.updateConnection(config);
    await _credentialRepository.saveCredentials(
      connectionId: config.id,
      password: password,
      privateKey: privateKey,
    );
    notifyStorageListeners();
  }

  /// 删除结构数据后同步清理独立安全凭据和 tmux 元数据。
  Future<void> deleteConnection(String id) async {
    await init();
    await _connectionRepository.deleteConnection(id);
    await _credentialRepository.deleteCredentials(id);
    await _terminalMetadataStore.removeRestorableTmuxSessionsForConnection(id);
    notifyStorageListeners();
  }

  Future<void> deleteConnections(Iterable<String> ids) async {
    for (final id in ids) {
      await deleteConnection(id);
    }
  }

  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    await init();
    await _connectionRepository.reorderConnections(oldIndex, newIndex);
    notifyStorageListeners();
  }

  /// 持久化 Host Key 信任元数据，Owner 仍是 Connection Core Repository。
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) => _hostKeyRepository.trustHostKey(
    connectionId,
    algorithm: algorithm,
    fingerprint: fingerprint,
    trustedAt: trustedAt,
  );

  Future<String?> getPassword(String id) =>
      _credentialRepository.getPassword(id);

  Future<String?> getPrivateKey(String id) =>
      _credentialRepository.getPrivateKey(id);

  @override
  Future<List<feature_ai.AiChatRecord>> loadAiChats() async =>
      (await _requireAiRepository()).loadChats();

  @override
  Future<void> saveAiChat(feature_ai.AiChatRecord chat) async {
    await (await _requireAiRepository()).saveChat(chat);
    notifyStorageListeners();
  }

  @override
  Future<void> deleteAiChat(String id) async {
    await (await _requireAiRepository()).deleteChat(id);
    notifyStorageListeners();
  }

  Future<void> replaceAiChats(List<feature_ai.AiChatRecord> chats) async {
    await (await _requireAiRepository()).replaceChats(chats);
    notifyStorageListeners();
  }

  @override
  Future<List<feature_ai.AiSkillRecord>> loadAiSkills() =>
      _runExclusiveAiSkillOperation(_loadAiSkills);

  @override
  Future<void> saveAiSkill(feature_ai.AiSkillRecord skill) =>
      _runExclusiveAiSkillOperation(() => _saveAiSkill(skill));

  @override
  Future<bool> saveAiSkillIfUnchanged(
    feature_ai.AiSkillRecord expected,
    feature_ai.AiSkillRecord next,
  ) {
    if (next.id != expected.id) {
      throw ArgumentError.value(next.id, 'next', 'AI skill id must match.');
    }
    return _runExclusiveAiSkillOperation(() async {
      final current = (await _loadAiSkills()).where(
        (item) => item.id == expected.id,
      );
      final item = current.isEmpty ? null : current.first;
      if (item == null ||
          jsonEncode(item.toJson()) != jsonEncode(expected.toJson())) {
        return false;
      }
      await _saveAiSkill(next);
      return true;
    });
  }

  @override
  Future<void> deleteAiSkill(String id) =>
      _runExclusiveAiSkillOperation(() => _deleteAiSkill(id));

  @override
  Future<List<feature_ai.AgentRunMetrics>> loadAgentRunMetrics() async =>
      (await _requireAiRepository()).loadRunMetrics();

  @override
  Future<void> saveAgentRunMetrics(feature_ai.AgentRunMetrics metrics) async {
    await (await _requireAiRepository()).saveRunMetrics(metrics);
    notifyStorageListeners();
  }

  Future<void> replaceAgentRunMetrics(
    List<feature_ai.AgentRunMetrics> metrics,
  ) async {
    await (await _requireAiRepository()).replaceRunMetrics(metrics);
    notifyStorageListeners();
  }

  @override
  Future<List<feature_ai.AgentTraceEvent>> loadAgentTraceEvents(
    String runId,
  ) async => (await _requireAiRepository()).loadTraceEvents(runId);

  @override
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => (_requireAiRepository()).then(
    (repository) =>
        repository.loadRecentTraceRunIdsForChat(chatId, limit: limit),
  );

  @override
  Future<void> saveAgentTraceEvent(feature_ai.AgentTraceEvent event) async {
    await (await _requireAiRepository()).saveTraceEvent(event);
    notifyStorageListeners();
  }

  @override
  Future<void> saveAgentTraceEvents(
    List<feature_ai.AgentTraceEvent> events,
  ) async {
    await (await _requireAiRepository()).saveTraceEvents(events);
    notifyStorageListeners();
  }

  @override
  Future<void> deleteAgentTraceEvents(String runId) async {
    await (await _requireAiRepository()).deleteTraceEvents(runId);
    notifyStorageListeners();
  }

  @override
  Future<feature_ai.AiConnectionSettings> loadAiConnectionSettings() =>
      _runExclusiveAiSettingsOperation(
        () => SettingsOps(this).loadAiConnectionSettings(),
      );

  @override
  Future<void> saveAiConnectionSettings(
    feature_ai.AiConnectionSettings settings,
  ) => saveAiConnectionSettingsLegacy(
    baseUrl: settings.baseUrl,
    model: settings.model,
    helperModel: settings.helperModel,
    auditModel: settings.auditModel,
    modelFallbackPolicy: settings.modelFallbackPolicy,
    contextWindowTokens: settings.contextWindowTokens,
    timeoutSeconds: settings.timeoutSeconds,
    deepSeekThinkingEnabled: settings.deepSeekThinkingEnabled,
    deepSeekReasoningEffort: settings.deepSeekReasoningEffort,
    openAiReasoningEffort: settings.openAiReasoningEffort,
    webSearchEnabled: settings.webSearchEnabled,
    webSearchMaxResults: settings.webSearchMaxResults,
    webSearchEngine: settings.webSearchEngine,
    multiAgentEnabled: settings.multiAgentEnabled,
    multiAgentMaxAgents: settings.multiAgentMaxAgents,
    postToolReviewEnabled: settings.postToolReviewEnabled,
    toolCallBudget: settings.toolCallBudget,
    agentLoopMode: settings.agentLoopMode,
    maxImageSizeBytes: settings.maxImageSizeBytes,
    maxFileSizeBytes: settings.maxFileSizeBytes,
    quarkSearchEndpoint: settings.quarkSearchEndpoint,
    useCustomPrompts: settings.useCustomPrompts,
    customSystemPrompt: settings.customSystemPrompt,
    customPlannerPrompt: settings.customPlannerPrompt,
    customOperatorPrompt: settings.customOperatorPrompt,
    customExplorePrompt: settings.customExplorePrompt,
    customReviewerPrompt: settings.customReviewerPrompt,
    customSummarizerPrompt: settings.customSummarizerPrompt,
    customCoordinatorPrompt: settings.customCoordinatorPrompt,
    apiFormat: settings.apiFormat,
  );

  @override
  Future<void> saveAiConnectionSettingsLegacy({
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
    int? multiAgentMaxAgents,
    bool? multiAgentEnabled,
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
    feature_ai.LlmApiFormat? apiFormat,
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
  Future<feature_ai.AiRuntimeConnectionSnapshot>
  loadAiRuntimeConnectionSnapshot() async {
    final settings = await loadAiConnectionSettings();
    return feature_ai.AiRuntimeConnectionSnapshot(
      settings: settings,
      apiKey: (await getAiApiKey()).trim(),
      quarkApiKey: (await getQuarkApiKey())?.trim() ?? '',
      aliyunApiKey: (await getAliyunApiKey() ?? '').trim(),
    );
  }

  @override
  Future<String> getAiApiKey() async =>
      await SettingsOps(this).getAiApiKey() ?? '';

  @override
  Future<String?> getAiApiKeyById(String id) =>
      SettingsOps(this).getAiApiKeyById(id);

  @override
  Future<List<feature_ai.AiApiKeyHistoryEntry>> loadAiApiKeyHistory() =>
      SettingsOps(this).loadAiApiKeyHistory();

  @override
  Future<List<String>> loadAiBaseUrlHistory() =>
      SettingsOps(this).loadAiBaseUrlHistory();

  @override
  Future<List<String>> loadCachedAiModels({String? baseUrl}) =>
      SettingsOps(this).loadCachedAiModels(baseUrl: baseUrl);

  @override
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) => SettingsOps(this).saveCachedAiModels(baseUrl: baseUrl, models: models);

  @override
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) =>
      SettingsOps(this).removeAiBaseUrlHistoryEntry(baseUrl);

  @override
  Future<void> removeAiApiKeyHistoryEntry(String id) =>
      _runExclusiveAiSettingsOperation(
        () => SettingsOps(this).removeAiApiKeyHistoryEntry(id),
      );

  @override
  Future<String?> getAliyunApiKey() => SettingsOps(this).getAliyunApiKey();

  @override
  Future<List<feature_playbook.Playbook>> loadPlaybooks() =>
      _playbookRepository.loadPlaybooks();

  @override
  Future<void> savePlaybook(feature_playbook.Playbook playbook) =>
      _playbookRepository.savePlaybook(playbook);

  Future<void> deletePlaybook(String id) =>
      _playbookRepository.deletePlaybook(id);

  Future<bool> savePlaybookIfActionUnchanged({
    required String playbookId,
    required String expectedActionFingerprint,
    required feature_playbook.Playbook playbook,
  }) => _playbookRepository.savePlaybookIfActionUnchanged(
    playbookId: playbookId,
    expectedActionFingerprint: expectedActionFingerprint,
    playbook: playbook,
  );

  @override
  Future<String> exportAppDataJson() => _exportAppDataJson();

  @override
  Future<void> importAppDataJson(String jsonText) =>
      _importAppDataJson(jsonText);

  @override
  bool get isSecretCacheEnabled => _secretCacheEnabled;

  @override
  int get secretCacheTtlMinutes => _secretCacheTtl.inMinutes;

  Duration get secretCacheTtl => _secretCacheTtl;

  @override
  Future<void> setSecretCacheEnabled(bool enabled) =>
      SettingsOps(this).setSecretCacheEnabled(enabled);

  @override
  Future<void> setSecretCacheTtl(Duration ttl) =>
      SettingsOps(this).setSecretCacheTtl(ttl);

  @override
  void clearSecretCache() => SettingsOps(this).clearSecretCache();

  @override
  Future<int> getAiRequestTimeoutSeconds() =>
      SettingsOps(this).getAiRequestTimeoutSeconds();

  @override
  Future<List<feature_ai.AiSshSessionSnapshot>>
  loadRestorableTmuxSessions() async {
    final sessions = await _terminalMetadataStore.loadRestorableTmuxSessions();
    return List.unmodifiable([
      for (final item in sessions)
        feature_ai.AiSshSessionSnapshot(
          id: item.sessionId,
          connectionId: item.connectionId,
          connectionName: getConnection(item.connectionId)?.name ?? 'SSH',
          displayName: item.displayName,
          state: feature_ai.AiSshConnectionState.disconnected,
          isConnected: false,
          createdAt: item.updatedAt,
          updatedAt: item.updatedAt,
          tmuxSessionName: item.tmuxSessionName,
        ),
    ]);
  }

  /// SSH Service 使用的独立终端元数据入口。
  TerminalSessionMetadataStore get terminalMetadataStore =>
      _terminalMetadataStore;

  @override
  Map<String, ssh_core.SshTargetBinding> captureConnectionTargetBindings(
    Iterable<String> connectionIds,
  ) => Map.unmodifiable({
    for (final id in connectionIds.toSet())
      if (getConnection(id) != null)
        id: ssh_core.SshTargetBinding.fromConfig(getConnection(id)!),
  });

  @override
  Future<ssh_core.SshRuntimeTarget?> resolveConnectionTarget(
    ssh_core.SshTargetBinding binding,
  ) async {
    final config = getConnection(binding.id);
    if (!binding.matches(config)) return null;
    final password = await _credentialRepository.getPassword(binding.id);
    final privateKey = await _credentialRepository.getPrivateKey(binding.id);
    return ssh_core.SshRuntimeTarget(
      binding: binding,
      config: config!,
      credentials: ssh_core.SshCredentials(
        password: password,
        privateKey: privateKey,
      ),
    );
  }

  /// 注册备份导入后的 App 设置刷新回调。
  void registerOnImportCallback(FutureOr<void> Function() callback) {
    if (!_onImportCallbacks.contains(callback)) {
      _onImportCallbacks.add(callback);
    }
  }

  /// 移除备份导入回调。
  void unregisterOnImportCallback(FutureOr<void> Function() callback) {
    _onImportCallbacks.remove(callback);
  }

  /// 通知设置、技能和备份页面刷新。
  void notifyStorageListeners() {
    if (!_disposed) notifyListeners();
  }

  /// 等待所有防抖偏好写入完成，供 App Scope 生命周期统一调用。
  Future<void> flushPendingWrites() async {
    final keys = _pendingProtectedPrefWrites.keys.toList(growable: false);
    await Future.wait(keys.map(_flushProtectedPrefWrite));
  }

  /// 测试可注入独立 AI Repository；生产装配仍由 AiModule 懒加载。
  @visibleForTesting
  void attachAiRepositoryLoader(
    Future<feature_ai.AiRepository> Function() loader,
  ) {
    if (_disposed) throw StateError('AI storage adapter has been shut down.');
    _aiRepositoryLoader = loader;
    _aiRepositoryFuture = null;
  }

  /// 释放适配器自身的偏好引用；ai.db 由 AiModule 关闭。
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    await flushPendingWrites();
    await _terminalMetadataStore.dispose();
    _prefs = null;
    _secretCache.clear();
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  Future<feature_ai.AiRepository> _requireAiRepository() {
    final existing = _aiRepositoryFuture;
    if (existing != null) return existing;
    final loader = _aiRepositoryLoader;
    if (loader != null) return _aiRepositoryFuture = loader();
    return _aiRepositoryFuture = _initializeAiModuleAndReadRepository();
  }

  Future<feature_ai.AiRepository> _initializeAiModuleAndReadRepository() async {
    await _aiModule.initialize();
    return _aiModule.repository;
  }

  Future<T> _runExclusiveAiSettingsOperation<T>(
    Future<T> Function() operation,
  ) async {
    return operation();
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
        await active;
        continue;
      }
      final ticket = Completer<void>();
      _aiSkillOperation = ticket.future;
      try {
        return await runZoned(
          operation,
          zoneValues: {_aiSkillOperationZoneKey: _aiSkillOperationOwner},
        );
      } finally {
        if (identical(_aiSkillOperation, ticket.future)) {
          _aiSkillOperation = null;
        }
        if (!ticket.isCompleted) ticket.complete();
      }
    }
  }

  Future<String?> _readSecure(String key) async =>
      _secureStorage.read(key: key);

  Future<void> _writeSecure(String key, String value) async {
    await _secureStorage.write(key: key, value: value);
  }

  Future<void> _deleteSecure(String key) async {
    await _secureStorage.delete(key: key);
  }
}

/// AI API Key 的进程内缓存条目；只保存短期值并受 TTL 控制。
final class _MemorySecret {
  const _MemorySecret({required this.value, required this.loadedAt});

  final String? value;
  final DateTime loadedAt;
}
