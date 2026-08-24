// 测试用 App 存储组合器。
//
// 该夹具只用于把旧测试场景接到当前的 AppAiStorageAdapter、Connection
// Repository、Playbook Repository 和终端元数据 Owner。它不恢复生产中的
// 统一存储门面，也不创建共享业务数据库；每个测试实例都拥有独立的
// 内存 Repository 和显式的关闭路径。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as playbook;
import 'package:feature_rag/feature_rag.dart' as rag;
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ai_storage_adapter.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/remote_target_scope.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/services/ssh_service.dart'
    hide TerminalHistoryRecord;
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';
import 'package:ssh_mobile/app/monitoring_feature_adapters.dart';
import 'package:ssh_mobile/app/playbook_feature_adapters.dart';

/// 测试中替代旧统一存储外观的组合器。
class TestStorageAdapter extends ChangeNotifier
    implements playbook.PlaybookRepository {
  /// 创建一组完全隔离的内存 Repository。
  TestStorageAdapter({
    // 这些参数只为迁移旧测试的构造调用保留，生产代码不再创建
    // 共享业务数据库；测试数据统一由下方的内存 Repository 管理。
    Object? database,
    Object Function()? databaseFactory,
    Future<void> Function()? initializationCheckpoint,
  }) {
    assert(database == null || databaseFactory == null);
    final connections = _TestConnectionRepository();
    final credentials = _TestCredentialRepository();
    final hostKeys = _TestHostKeyRepository(connections);
    final playbooks = _TestPlaybookRepository();
    final terminalMetadata = TerminalSessionMetadataStore();
    connectionRepository = connections;
    credentialRepository = credentials;
    hostKeyRepository = hostKeys;
    playbookRepository = playbooks;
    terminalMetadataStore = terminalMetadata;
    _delegate = AppAiStorageAdapter(
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      hostKeyRepository: hostKeyRepository,
      playbookRepository: playbookRepository,
      aiModule: ai.AiModule(),
      terminalMetadataStore: terminalMetadataStore,
      initializationCheckpoint: initializationCheckpoint,
    );
    _delegate.attachAiRepositoryLoader(_loadDefaultAiRepository);
  }

  late final ConnectionRepository connectionRepository;
  late final CredentialRepository credentialRepository;
  late final HostKeyRepository hostKeyRepository;
  late final playbook.PlaybookRepository playbookRepository;
  late final TerminalSessionMetadataStore terminalMetadataStore;
  final InMemorySftpPathHistoryStore sftpPathHistory =
      InMemorySftpPathHistoryStore();
  late final AppAiStorageAdapter _delegate;
  final List<ai.AiDatabase> _ownedAiDatabases = [];
  final List<TestRagService> _ownedRagServices = [];

  /// 真实 AI Port 视图，供测试显式注入 Feature。
  ai.AiStoragePort get aiStoragePort => _TestAiStoragePort(this);

  /// 真实 App AI 适配器，供仍处于 App Shell 的旧 RAG 兼容服务使用。
  AppAiStorageAdapter get aiStorage => _delegate;

  Future<void> get initFuture => _delegate.initFuture;
  bool get initialized => _delegate.initialized;
  bool get powerGuideSeen => _delegate.powerGuideSeen;
  List<ConnectionConfig> get connections => _delegate.connections;
  ConnectionConfig? getConnection(String id) => _delegate.getConnection(id);
  List<int> get secretCacheTtlOptionsMinutes =>
      _delegate.secretCacheTtlOptionsMinutes;
  bool get isSecretCacheEnabled => _delegate.isSecretCacheEnabled;
  int get secretCacheTtlMinutes => _delegate.secretCacheTtlMinutes;
  Duration get secretCacheTtl => _delegate.secretCacheTtl;

  Future<void> init() => _delegate.init();
  Future<void> initialize() => _delegate.initialize();

  Future<List<ConnectionConfig>> loadConnections() async {
    await init();
    return connections;
  }

  Future<void> addConnection(ConnectionConfig config) =>
      _delegate.addConnection(config);

  Future<void> updateConnection(ConnectionConfig config) =>
      _delegate.updateConnection(config);

  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) => _delegate.trustHostKey(
    connectionId,
    algorithm: algorithm,
    fingerprint: fingerprint,
    trustedAt: trustedAt,
  );

  Future<void> deleteConnection(String id) => _delegate.deleteConnection(id);

  Future<void> deleteConnections(Iterable<String> ids) =>
      _delegate.deleteConnections(ids);

  /// 测试专用的目标绑定 CAS 辅助；生产 CAS 通过 Core Repository 的显式
  /// 读写组合完成，夹具保留该方法以覆盖审批目标不应被旧快照覆盖的行为。
  Future<bool> updateConnectionIfMatches(
    ConnectionTargetBinding binding,
    ConnectionConfig next,
  ) async {
    final current = getConnection(binding.id);
    if (current == null || !binding.matches(current)) return false;
    await updateConnection(next);
    return true;
  }

  /// 测试专用的条件删除辅助。
  Future<bool> deleteConnectionIfMatches(
    ConnectionTargetBinding binding,
  ) async {
    final current = getConnection(binding.id);
    if (current == null || !binding.matches(current)) return false;
    await deleteConnection(binding.id);
    return true;
  }

  /// 测试专用的完整快照 CAS 辅助，避免回归已删除的统一存储 API。
  Future<bool> updateConnectionFromSnapshotIfUnchanged({
    required ConnectionConfig expected,
    required ConnectionConfig next,
  }) async {
    final current = getConnection(expected.id);
    if (current == null ||
        current.toJson().toString() != expected.toJson().toString()) {
      return false;
    }
    await updateConnection(next);
    return true;
  }

  Future<void> reorderConnections(int oldIndex, int newIndex) =>
      _delegate.reorderConnections(oldIndex, newIndex);

  Future<String?> getPassword(String id) => _delegate.getPassword(id);
  Future<String?> getPrivateKey(String id) => _delegate.getPrivateKey(id);

  /// 捕获旧 App Shell 测试所使用的目标绑定；运行时仍由 Core Port 校验。
  Map<String, ConnectionTargetBinding> captureConnectionTargetBindings(
    Iterable<String> ids,
  ) => {
    for (final id in ids)
      if (getConnection(id) != null)
        id: ConnectionTargetBinding.fromConfig(getConnection(id)!),
  };

  Future<ConnectionRuntimeTarget?> resolveConnectionTarget(
    ConnectionTargetBinding binding,
  ) => RemoteTargetScope.resolveBinding(
    binding,
    connectionRepository: connectionRepository,
    credentialRepository: credentialRepository,
  );

  Future<List<ai.AiChatRecord>> loadAiChats() => _delegate.loadAiChats();
  Future<void> saveAiChat(ai.AiChatRecord chat) => _delegate.saveAiChat(chat);
  Future<void> deleteAiChat(String id) => _delegate.deleteAiChat(id);
  Future<void> replaceAiChats(List<ai.AiChatRecord> chats) =>
      _delegate.replaceAiChats(chats);
  Future<List<ai.AiSkillRecord>> loadAiSkills() => _delegate.loadAiSkills();
  Future<void> saveAiSkill(ai.AiSkillRecord skill) =>
      _delegate.saveAiSkill(skill);
  Future<bool> saveAiSkillIfUnchanged(
    ai.AiSkillRecord expected,
    ai.AiSkillRecord next,
  ) => _delegate.saveAiSkillIfUnchanged(expected, next);
  Future<void> deleteAiSkill(String id) => _delegate.deleteAiSkill(id);
  Future<List<ai.AgentRunMetrics>> loadAgentRunMetrics() =>
      _delegate.loadAgentRunMetrics();
  Future<void> saveAgentRunMetrics(ai.AgentRunMetrics metrics) =>
      _delegate.saveAgentRunMetrics(metrics);
  Future<void> replaceAgentRunMetrics(List<ai.AgentRunMetrics> metrics) =>
      _delegate.replaceAgentRunMetrics(metrics);
  Future<List<ai.AgentTraceEvent>> loadAgentTraceEvents(String runId) =>
      _delegate.loadAgentTraceEvents(runId);
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => _delegate.loadRecentAgentTraceRunIdsForChat(chatId, limit: limit);
  Future<void> saveAgentTraceEvent(ai.AgentTraceEvent event) =>
      _delegate.saveAgentTraceEvent(event);
  Future<void> saveAgentTraceEvents(List<ai.AgentTraceEvent> events) =>
      _delegate.saveAgentTraceEvents(events);
  Future<void> deleteAgentTraceEvents(String runId) =>
      _delegate.deleteAgentTraceEvents(runId);

  Future<ai.AiConnectionSettings> loadAiConnectionSettings() =>
      _delegate.loadAiConnectionSettings();

  /// 兼容旧测试的增量设置方法，底层转发到 AI Port 的明确方法。
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
    ai.LlmApiFormat? apiFormat,
  }) => _delegate.saveAiConnectionSettingsLegacy(
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
  );

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
    ai.LlmApiFormat? apiFormat,
  }) => saveAiConnectionSettings(
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
  );

  Future<ai.AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot() =>
      _delegate.loadAiRuntimeConnectionSnapshot();

  Future<String?> getAiApiKey() async {
    final value = await _delegate.getAiApiKey();
    return value.isEmpty ? null : value;
  }

  Future<String?> getAiApiKeyById(String id) => _delegate.getAiApiKeyById(id);
  Future<List<ai.AiApiKeyHistoryEntry>> loadAiApiKeyHistory() =>
      _delegate.loadAiApiKeyHistory();
  Future<List<String>> loadAiBaseUrlHistory() =>
      _delegate.loadAiBaseUrlHistory();
  Future<List<String>> loadCachedAiModels({String? baseUrl}) =>
      _delegate.loadCachedAiModels(baseUrl: baseUrl);
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) => _delegate.saveCachedAiModels(baseUrl: baseUrl, models: models);
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) =>
      _delegate.removeAiBaseUrlHistoryEntry(baseUrl);
  Future<void> removeAiApiKeyHistoryEntry(String id) =>
      _delegate.removeAiApiKeyHistoryEntry(id);
  Future<String?> getQuarkApiKey() async {
    return _delegate.getQuarkApiKey();
  }

  Future<void> saveQuarkApiKey(String key) =>
      _delegate.saveAiConnectionSettingsLegacy(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-v4-flash',
        quarkApiKey: key,
      );
  Future<String?> getAliyunApiKey() async {
    final value = await _delegate.getAliyunApiKey();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> saveAliyunApiKey(String key) => _delegate.saveAliyunApiKey(key);
  Future<String?> getSelectedAiApiKeyId() => _delegate.getSelectedAiApiKeyId();
  Future<void> selectAiApiKey(String id) => _delegate.selectAiApiKey(id);
  Future<void> deleteAiApiKey(String id) => _delegate.deleteAiApiKey(id);
  Future<int> getAiRequestTimeoutSeconds() =>
      _delegate.getAiRequestTimeoutSeconds();
  Future<void> setSecretCacheEnabled(bool enabled) =>
      _delegate.setSecretCacheEnabled(enabled);
  Future<void> setSecretCacheTtl(Duration ttl) =>
      _delegate.setSecretCacheTtl(ttl);
  void clearSecretCache() => _delegate.clearSecretCache();

  Future<List<ai.AiSshSessionSnapshot>> loadRestorableTmuxSessions() =>
      _delegate.loadRestorableTmuxSessions();

  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() async {
    return terminalMetadataStore.loadTerminalHistoryRecords();
  }

  Future<void> saveTerminalHistoryRecord(TerminalHistoryRecord record) =>
      terminalMetadataStore.saveTerminalHistoryRecord(record);

  Future<void> removeTerminalHistoryRecord(String sessionId) =>
      terminalMetadataStore.removeTerminalHistoryRecord(sessionId);

  Future<List<SftpRecentPathRecord>> loadRecentPaths(
    String connectionId, {
    int limit = 30,
  }) => sftpPathHistory.loadRecentPaths(connectionId, limit: limit);

  Future<void> recordVisitedPath(String connectionId, String path) =>
      sftpPathHistory.recordVisitedPath(connectionId, path);

  Future<SftpFavoritePathRecord> addFavoritePath(
    String connectionId,
    String path,
    String name,
  ) => sftpPathHistory.addFavoritePath(connectionId, path, name);

  Future<void> removeFavoritePath(String id) =>
      sftpPathHistory.removeFavoritePath(id);

  Future<void> renameFavoritePath(String id, String name) =>
      sftpPathHistory.renameFavoritePath(id, name);

  Future<List<SftpFavoritePathRecord>> loadFavoritePaths(String connectionId) =>
      sftpPathHistory.loadFavoritePaths(connectionId);

  Future<SftpFavoritePathRecord?> findFavoritePath(
    String connectionId,
    String path,
  ) => sftpPathHistory.findFavoritePath(connectionId, path);

  @override
  Future<List<playbook.Playbook>> loadPlaybooks() =>
      playbookRepository.loadPlaybooks();

  @override
  Future<void> savePlaybook(playbook.Playbook item) =>
      playbookRepository.savePlaybook(item);

  @override
  Future<void> deletePlaybook(String id) =>
      playbookRepository.deletePlaybook(id);

  @override
  Future<int?> savePlaybookIfRevisionMatches({
    required String playbookId,
    required int expectedRevision,
    required playbook.Playbook playbook,
  }) => playbookRepository.savePlaybookIfRevisionMatches(
    playbookId: playbookId,
    expectedRevision: expectedRevision,
    playbook: playbook,
  );

  @override
  Future<void> saveRunSnapshot(playbook.PlaybookRunSnapshot snapshot) =>
      playbookRepository.saveRunSnapshot(snapshot);

  Future<String> exportAppDataJson() => _delegate.exportAppDataJson();
  Future<void> importAppDataJson(String jsonText) =>
      _delegate.importAppDataJson(jsonText);

  void attachAiRepositoryLoader(Future<ai.AiRepository> Function() loader) {
    _delegate.attachAiRepositoryLoader(loader);
  }

  void registerOnImportCallback(FutureOr<void> Function() callback) =>
      _delegate.registerOnImportCallback(callback);

  Future<void> markPowerGuideSeen() async {
    // Power Guide 的生产 Owner 已迁移到 AppSettings；测试夹具只保留
    // 旧查询面，避免把该状态重新写回 AI 数据库。
    await init();
  }

  /// 关闭 Repository、SharedPreferences 写入队列和测试专用 AI 数据库。
  Future<void> shutdown() async {
    for (final service in List<TestRagService>.of(_ownedRagServices)) {
      await service.close();
    }
    _ownedRagServices.clear();
    await _delegate.shutdown();
    for (final database in _ownedAiDatabases) {
      await database.dispose();
    }
    _ownedAiDatabases.clear();
  }

  void _registerRagService(TestRagService service) {
    _ownedRagServices.add(service);
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }

  Future<ai.AiRepository> _loadDefaultAiRepository() async {
    final database = ai.AiDatabase.forTesting(NativeDatabase.memory());
    _ownedAiDatabases.add(database);
    return ai.DriftAiRepository(database, const _TestAiTextProtection());
  }
}

/// 创建使用测试夹具中显式 Repository 的旧 App SSH 服务。
SshService createTestSshService(
  TestStorageAdapter storage, {
  AppSettings? appSettings,
}) => SshService(
  connectionRepository: storage.connectionRepository,
  credentialRepository: storage.credentialRepository,
  hostKeyRepository: storage.hostKeyRepository,
  terminalMetadataStore: storage.terminalMetadataStore,
  appSettings: appSettings,
);

/// 创建使用测试夹具中显式 Repository 的旧 App SFTP 服务。
SftpService createTestSftpService(
  TestStorageAdapter storage, {
  SftpPathHistoryStore? pathHistoryStore,
}) => SftpService(
  connectionRepository: storage.connectionRepository,
  credentialRepository: storage.credentialRepository,
  hostKeyRepository: storage.hostKeyRepository,
  pathHistoryStore: pathHistoryStore ?? storage.sftpPathHistory,
);

/// 创建使用测试夹具中显式 Ports 的 Monitoring Feature 服务。
monitoring.MonitoringService createTestPerformanceMonitorService(
  SshService sshService,
  TestStorageAdapter storage, {
  AppSettings? appSettings,
}) => monitoring.MonitoringService(
  sshPort: AppMonitoringSshAdapter(sshService),
  connectionCatalog: AppMonitoringConnectionCatalogAdapter(
    storage.connectionRepository,
  ),
  logger: const _TestMonitoringLogger(),
  background: appSettings == null
      ? null
      : AppMonitoringBackgroundAdapter(appSettings),
);

final class _TestMonitoringLogger implements monitoring.MonitoringLoggerPort {
  const _TestMonitoringLogger();

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

/// 创建使用显式 Feature Ports 的 Playbook Service。
playbook.PlaybookService createTestPlaybook({
  required playbook.PlaybookRepository repository,
  required SshService sshService,
}) => playbook.PlaybookService(
  repository: repository,
  sshPort: AppPlaybookSshAdapter(sshService),
  logger: const _TestPlaybookLogger(),
);

final class _TestPlaybookLogger implements playbook.PlaybookLoggerPort {
  const _TestPlaybookLogger();

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

/// 测试边界的 RAG Module Owner；Service、数据库和缓存仍按 Package 生命周期
/// 创建，App 测试不再构造旧 RAG facade。
Future<TestRagService> createTestRagService(
  TestStorageAdapter storage, {
  rag.RagSearchMode searchMode = rag.RagSearchMode.bm25,
}) async {
  final cacheDirectory = Directory.systemTemp.createTempSync(
    'ssh-mobile-rag-test-',
  );
  final settings = _TestRagSettings(storage.aiStorage, searchMode);
  final module = rag.RagModule(
    databaseFactory: () => rag.RagDatabase.forTesting(NativeDatabase.memory()),
    cacheStoreFactory: () =>
        rag.RagCacheStore(directoryFactory: () async => cacheDirectory),
  );
  await module.register(
    ModuleContext.fromMap({
      rag.RagSettingsPort: settings,
      rag.RagLoggerPort: const _TestRagLogger(),
    }),
  );
  await module.initialize();
  await module.activate();
  final service = TestRagService(module, cacheDirectory);
  storage._registerRagService(service);
  return service;
}

final class TestRagService extends ChangeNotifier implements rag.RagCapability {
  TestRagService(this._module, this._cacheDirectory) {
    _module.service.addListener(notifyListeners);
  }

  final rag.RagModule _module;
  final Directory _cacheDirectory;
  Future<void>? _closeFuture;

  rag.RagService get service => _module.service;

  List<rag.RagDocumentMetadata> get documents => service.documents;

  bool get isLoading => service.isLoading;

  bool get isInitialized => service.isInitialized;

  Future<void> init({bool force = false}) => service.init(force: force);

  Future<rag.RagDocumentMetadata> addDocument({
    required String name,
    required List<int> bytes,
    required String mimeType,
  }) => service.addDocument(name: name, bytes: bytes, mimeType: mimeType);

  Future<void> deleteDocument(String documentId) =>
      service.deleteDocument(documentId);

  @override
  Future<List<rag.RagChunk>> retrieve(
    String query, {
    int limit = 3,
    Set<String>? filterDocumentIds,
    String? searchMode,
    String? aliyunApiKey,
  }) => service.retrieve(
    query,
    limit: limit,
    filterDocumentIds: filterDocumentIds,
    searchMode: searchMode,
    aliyunApiKey: aliyunApiKey,
  );

  /// 等待 Module 关闭，用于 App 测试夹具的显式生命周期收尾。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    _module.service.removeListener(notifyListeners);
    await _module.dispose();
    try {
      _cacheDirectory.deleteSync(recursive: true);
    } on FileSystemException {
      // Cache cleanup is best effort when a platform still holds a file handle.
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

final class _TestRagSettings extends ChangeNotifier
    implements rag.RagSettingsPort {
  _TestRagSettings(this._storage, this.searchMode);

  final AppAiStorageAdapter _storage;

  @override
  final rag.RagSearchMode searchMode;

  @override
  bool get isEnglish => false;

  @override
  Future<String?> getAliyunApiKey() => _storage.getAliyunApiKey();

  @override
  Future<void> saveAliyunApiKey(String key) => _storage.saveAliyunApiKey(key);
}

final class _TestRagLogger implements rag.RagLoggerPort {
  const _TestRagLogger();

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

/// 测试边界的 AI Port 视图；它把可空的测试密钥转换为 Port 约定的空串。
final class _TestAiStoragePort implements ai.AiStoragePort {
  const _TestAiStoragePort(this._owner);

  final TestStorageAdapter _owner;

  @override
  List<ConnectionConfig> get connections => _owner.connections;

  @override
  ConnectionConfig? getConnection(String id) => _owner.getConnection(id);

  @override
  Future<List<ai.AiChatRecord>> loadAiChats() => _owner.loadAiChats();
  @override
  Future<void> saveAiChat(ai.AiChatRecord chat) => _owner.saveAiChat(chat);
  @override
  Future<void> deleteAiChat(String id) => _owner.deleteAiChat(id);
  @override
  Future<List<ai.AiSkillRecord>> loadAiSkills() => _owner.loadAiSkills();
  @override
  Future<void> saveAiSkill(ai.AiSkillRecord skill) => _owner.saveAiSkill(skill);
  @override
  Future<bool> saveAiSkillIfUnchanged(
    ai.AiSkillRecord expected,
    ai.AiSkillRecord next,
  ) => _owner.saveAiSkillIfUnchanged(expected, next);
  @override
  Future<void> deleteAiSkill(String id) => _owner.deleteAiSkill(id);
  @override
  Future<List<ai.AgentRunMetrics>> loadAgentRunMetrics() =>
      _owner.loadAgentRunMetrics();
  @override
  Future<void> saveAgentRunMetrics(ai.AgentRunMetrics metrics) =>
      _owner.saveAgentRunMetrics(metrics);
  @override
  Future<List<ai.AgentTraceEvent>> loadAgentTraceEvents(String runId) =>
      _owner.loadAgentTraceEvents(runId);
  @override
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => _owner.loadRecentAgentTraceRunIdsForChat(chatId, limit: limit);
  @override
  Future<void> saveAgentTraceEvent(ai.AgentTraceEvent event) =>
      _owner.saveAgentTraceEvent(event);
  @override
  Future<void> saveAgentTraceEvents(List<ai.AgentTraceEvent> events) =>
      _owner.saveAgentTraceEvents(events);
  @override
  Future<void> deleteAgentTraceEvents(String runId) =>
      _owner.deleteAgentTraceEvents(runId);
  @override
  Future<ai.AiConnectionSettings> loadAiConnectionSettings() =>
      _owner.loadAiConnectionSettings();
  @override
  Future<void> saveAiConnectionSettings(ai.AiConnectionSettings settings) =>
      _owner.aiStorage.saveAiConnectionSettings(settings);
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
    ai.LlmApiFormat? apiFormat,
  }) => _owner.saveAiConnectionSettings(
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
  );
  @override
  Future<ai.AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot() =>
      _owner.loadAiRuntimeConnectionSnapshot();
  @override
  Future<String> getAiApiKey() async => await _owner.getAiApiKey() ?? '';
  @override
  Future<String?> getAiApiKeyById(String id) => _owner.getAiApiKeyById(id);
  @override
  Future<List<ai.AiApiKeyHistoryEntry>> loadAiApiKeyHistory() =>
      _owner.loadAiApiKeyHistory();
  @override
  Future<List<String>> loadAiBaseUrlHistory() => _owner.loadAiBaseUrlHistory();
  @override
  Future<List<String>> loadCachedAiModels({String? baseUrl}) =>
      _owner.loadCachedAiModels(baseUrl: baseUrl);
  @override
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) => _owner.saveCachedAiModels(baseUrl: baseUrl, models: models);
  @override
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) =>
      _owner.removeAiBaseUrlHistoryEntry(baseUrl);
  @override
  Future<void> removeAiApiKeyHistoryEntry(String id) =>
      _owner.removeAiApiKeyHistoryEntry(id);
  @override
  Future<String?> getAliyunApiKey() => _owner.getAliyunApiKey();
  @override
  Future<List<playbook.Playbook>> loadPlaybooks() => _owner.loadPlaybooks();
  @override
  Future<void> savePlaybook(playbook.Playbook item) =>
      _owner.savePlaybook(item);
  @override
  Future<String> exportAppDataJson() => _owner.exportAppDataJson();
  @override
  Future<void> importAppDataJson(String jsonText) =>
      _owner.importAppDataJson(jsonText);
  @override
  bool get isSecretCacheEnabled => _owner.isSecretCacheEnabled;
  @override
  int get secretCacheTtlMinutes => _owner.secretCacheTtlMinutes;
  @override
  Future<void> setSecretCacheEnabled(bool enabled) =>
      _owner.setSecretCacheEnabled(enabled);
  @override
  Future<void> setSecretCacheTtl(Duration ttl) => _owner.setSecretCacheTtl(ttl);
  @override
  void clearSecretCache() => _owner.clearSecretCache();
  @override
  Future<int> getAiRequestTimeoutSeconds() =>
      _owner.getAiRequestTimeoutSeconds();
  @override
  Future<List<ai.AiSshSessionSnapshot>> loadRestorableTmuxSessions() =>
      _owner.loadRestorableTmuxSessions();
  @override
  Map<String, ssh_core.SshTargetBinding> captureConnectionTargetBindings(
    Iterable<String> ids,
  ) => _owner.aiStorage.captureConnectionTargetBindings(ids);
  @override
  Future<ssh_core.SshRuntimeTarget?> resolveConnectionTarget(
    ssh_core.SshTargetBinding binding,
  ) => _owner.aiStorage.resolveConnectionTarget(binding);
}

/// 测试专用的可逆文本保护；只验证 Repository 的加密边界，不保存真实密钥。
final class _TestAiTextProtection implements ai.AiTextProtectionPort {
  const _TestAiTextProtection();

  @override
  Future<String> encrypt(String plainText) async =>
      'test:${base64Encode(utf8.encode(plainText))}';

  @override
  Future<String> decrypt(String storedText) async {
    if (!storedText.startsWith('test:')) return storedText;
    return utf8.decode(base64Decode(storedText.substring(5)));
  }
}

final class _TestConnectionRepository implements ConnectionRepository {
  final List<ConnectionConfig> _items = [];

  @override
  List<ConnectionConfig> get connections => List.unmodifiable(_items);

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async {
    return connections;
  }

  @override
  Future<void> addConnection(ConnectionConfig config) async {
    if (_items.any((item) => item.id == config.id)) {
      throw StateError('Connection already exists: ${config.id}');
    }
    _items.add(config.copyWith());
  }

  @override
  Future<void> updateConnection(ConnectionConfig config) async {
    final index = _items.indexWhere((item) => item.id == config.id);
    if (index < 0) throw StateError('Connection not found: ${config.id}');
    _items[index] = config.copyWith();
  }

  @override
  Future<void> deleteConnection(String id) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) throw StateError('Connection not found: $id');
    _items.removeAt(index);
  }

  @override
  Future<void> deleteConnections(List<String> ids) async {
    for (final id in ids) {
      await deleteConnection(id);
    }
  }

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _items.length) {
      throw RangeError.index(oldIndex, _items);
    }
    final item = _items.removeAt(oldIndex);
    final target = newIndex.clamp(0, _items.length);
    _items.insert(target, item);
  }

  @override
  ConnectionConfig? getConnection(String id) =>
      _items.where((item) => item.id == id).firstOrNull;

  void trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) {
    final config = getConnection(connectionId);
    if (config == null) throw StateError('Connection not found: $connectionId');
    config.hostKeyAlgorithm = algorithm;
    config.hostKeyFingerprint = fingerprint;
    config.hostKeyTrustedAt = trustedAt;
  }
}

final class _TestCredentialRepository implements CredentialRepository {
  final Map<String, String?> _passwords = {};
  final Map<String, String?> _privateKeys = {};

  @override
  Future<String?> getPassword(String connectionId) async =>
      _passwords[connectionId];

  @override
  Future<String?> getPrivateKey(String connectionId) async =>
      _privateKeys[connectionId];

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    _passwords[connectionId] = password;
    _privateKeys[connectionId] = privateKey;
  }

  @override
  Future<void> deleteCredentials(String connectionId) async {
    _passwords.remove(connectionId);
    _privateKeys.remove(connectionId);
  }
}

final class _TestHostKeyRepository implements HostKeyRepository {
  const _TestHostKeyRepository(this._connections);

  final _TestConnectionRepository _connections;

  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    _connections.trustHostKey(
      connectionId,
      algorithm: algorithm,
      fingerprint: fingerprint,
      trustedAt: trustedAt,
    );
  }
}

final class _TestPlaybookRepository implements playbook.PlaybookRepository {
  final List<playbook.Playbook> _items = [];

  @override
  Future<List<playbook.Playbook>> loadPlaybooks() async =>
      List.unmodifiable(_items);

  @override
  Future<void> savePlaybook(playbook.Playbook item) async {
    final index = _items.indexWhere((current) => current.id == item.id);
    final revision = index == -1 ? 1 : _items[index].revision + 1;
    if (index != -1) _items.removeAt(index);
    _items.add(item.copyWith(revision: revision));
  }

  @override
  Future<void> deletePlaybook(String id) async {
    _items.removeWhere((item) => item.id == id);
  }

  @override
  Future<int?> savePlaybookIfRevisionMatches({
    required String playbookId,
    required int expectedRevision,
    required playbook.Playbook playbook,
  }) async {
    final current = _items.where((item) => item.id == playbookId).firstOrNull;
    if (current == null || current.revision != expectedRevision) {
      return null;
    }
    final nextRevision = expectedRevision + 1;
    _items.remove(current);
    _items.add(playbook.copyWith(revision: nextRevision));
    return nextRevision;
  }

  @override
  Future<void> saveRunSnapshot(playbook.PlaybookRunSnapshot snapshot) async {}
}

extension<E> on Iterable<E> {
  E? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
