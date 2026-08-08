// AI Feature 的 App Shell 适配层。
//
// 这里仅把 AppRuntime 已经拥有的设置、Storage、SSH、SFTP 和监控实例
// 转换为 feature_ai 的 Port。适配器不创建第二份连接、数据库或 Timer，
// AI 的业务编排仍由 feature_ai Package 负责。

import 'package:app_core/app_core.dart' as app_core;
import 'package:connection_core/connection_core.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as playbook;
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../services/app_settings.dart';
import '../services/connection_target_binding.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';

// AI 工具的默认传输限制属于 AI Port 合约；App 适配层保留同样的默认值，
// 避免为了读取默认配置重新依赖 Package 内部兼容实现。
const int _defaultAiSftpDownloadLimitBytes = 50 * 1024 * 1024;
const int _defaultAiSftpTextEditLimitBytes = 2 * 1024 * 1024;

/// 将旧 StorageService 的兼容 API 接到 AI Port。
final class AppAiStorageAdapter implements ai.AiStoragePort {
  const AppAiStorageAdapter(this._storage);

  final StorageService _storage;

  @override
  List<ConnectionConfig> get connections => _storage.connections;

  @override
  ConnectionConfig? getConnection(String id) => _storage.getConnection(id);

  @override
  Future<List<ai.AiChatRecord>> loadAiChats() => _storage.loadAiChats();

  @override
  Future<void> saveAiChat(ai.AiChatRecord chat) => _storage.saveAiChat(chat);

  @override
  Future<void> deleteAiChat(String id) => _storage.deleteAiChat(id);

  @override
  Future<List<ai.AiSkillRecord>> loadAiSkills() => _storage.loadAiSkills();

  @override
  Future<void> saveAiSkill(ai.AiSkillRecord skill) =>
      _storage.saveAiSkill(skill);

  @override
  Future<bool> saveAiSkillIfUnchanged(
    ai.AiSkillRecord expected,
    ai.AiSkillRecord next,
  ) => _storage.saveAiSkillIfUnchanged(expected, next);

  @override
  Future<void> deleteAiSkill(String id) => _storage.deleteAiSkill(id);

  @override
  Future<List<ai.AgentRunMetrics>> loadAgentRunMetrics() =>
      _storage.loadAgentRunMetrics();

  @override
  Future<void> saveAgentRunMetrics(ai.AgentRunMetrics metrics) =>
      _storage.saveAgentRunMetrics(metrics);

  @override
  Future<List<ai.AgentTraceEvent>> loadAgentTraceEvents(String runId) =>
      _storage.loadAgentTraceEvents(runId);

  @override
  Future<List<String>> loadRecentAgentTraceRunIdsForChat(
    String chatId, {
    int limit = 20,
  }) => _storage.loadRecentAgentTraceRunIdsForChat(chatId, limit: limit);

  @override
  Future<void> saveAgentTraceEvent(ai.AgentTraceEvent event) =>
      _storage.saveAgentTraceEvent(event);

  @override
  Future<void> saveAgentTraceEvents(List<ai.AgentTraceEvent> events) =>
      _storage.saveAgentTraceEvents(events);

  @override
  Future<void> deleteAgentTraceEvents(String runId) =>
      _storage.deleteAgentTraceEvents(runId);

  @override
  Future<ai.AiConnectionSettings> loadAiConnectionSettings() =>
      _storage.loadAiConnectionSettings();

  @override
  Future<void> saveAiConnectionSettings(ai.AiConnectionSettings settings) =>
      _storage.saveAiConnectionSettings(
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
  }) => _storage.saveAiConnectionSettings(
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
      _storage.loadAiRuntimeConnectionSnapshot();

  @override
  Future<String> getAiApiKey() async => await _storage.getAiApiKey() ?? '';

  @override
  Future<String?> getAiApiKeyById(String id) => _storage.getAiApiKeyById(id);

  @override
  Future<List<ai.AiApiKeyHistoryEntry>> loadAiApiKeyHistory() =>
      _storage.loadAiApiKeyHistory();

  @override
  Future<List<String>> loadAiBaseUrlHistory() =>
      _storage.loadAiBaseUrlHistory();

  @override
  Future<List<String>> loadCachedAiModels({String? baseUrl}) =>
      _storage.loadCachedAiModels(baseUrl: baseUrl);

  @override
  Future<void> saveCachedAiModels({
    required String baseUrl,
    required List<String> models,
  }) => _storage.saveCachedAiModels(baseUrl: baseUrl, models: models);

  @override
  Future<void> removeAiBaseUrlHistoryEntry(String baseUrl) =>
      _storage.removeAiBaseUrlHistoryEntry(baseUrl);

  @override
  Future<void> removeAiApiKeyHistoryEntry(String id) =>
      _storage.removeAiApiKeyHistoryEntry(id);

  @override
  Future<String> getAliyunApiKey() async =>
      await _storage.getAliyunApiKey() ?? '';

  @override
  Future<List<playbook.Playbook>> loadPlaybooks() => _storage.loadPlaybooks();

  @override
  Future<void> savePlaybook(playbook.Playbook playbook) =>
      _storage.savePlaybook(playbook);

  @override
  Future<String> exportAppDataJson() => _storage.exportAppDataJson();

  @override
  Future<void> importAppDataJson(String jsonText) =>
      _storage.importAppDataJson(jsonText);

  @override
  bool get isSecretCacheEnabled => _storage.isSecretCacheEnabled;

  @override
  int get secretCacheTtlMinutes => _storage.secretCacheTtlMinutes;

  @override
  Future<void> setSecretCacheEnabled(bool enabled) =>
      _storage.setSecretCacheEnabled(enabled);

  @override
  Future<void> setSecretCacheTtl(Duration ttl) =>
      _storage.setSecretCacheTtl(ttl);

  @override
  void clearSecretCache() => _storage.clearSecretCache();

  @override
  Future<int> getAiRequestTimeoutSeconds() =>
      _storage.getAiRequestTimeoutSeconds();

  @override
  Future<List<ai.AiSshSessionSnapshot>> loadRestorableTmuxSessions() async {
    final result = <ai.AiSshSessionSnapshot>[];
    for (final item in await _storage.loadRestorableTmuxSessions()) {
      final connection = _storage.getConnection(item.connectionId);
      result.add(
        ai.AiSshSessionSnapshot(
          id: item.sessionId,
          connectionId: item.connectionId,
          connectionName: connection?.name ?? 'SSH',
          displayName: item.displayName,
          state: ai.AiSshConnectionState.disconnected,
          isConnected: false,
          createdAt: item.updatedAt,
          updatedAt: item.updatedAt,
          tmuxSessionName: item.tmuxSessionName,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  @override
  Map<String, ssh_core.SshTargetBinding> captureConnectionTargetBindings(
    Iterable<String> connectionIds,
  ) {
    final legacy = _storage.captureConnectionTargetBindings(connectionIds);
    return Map.unmodifiable({
      for (final entry in legacy.entries)
        entry.key: ssh_core.SshTargetBinding.fromConfig(entry.value.config),
    });
  }

  @override
  Future<ssh_core.SshRuntimeTarget?> resolveConnectionTarget(
    ssh_core.SshTargetBinding binding,
  ) async {
    final legacy = await _storage.resolveConnectionTarget(
      ConnectionTargetBinding.fromConfig(binding.config),
    );
    if (legacy == null) return null;
    return ssh_core.SshRuntimeTarget(
      binding: binding,
      config: legacy.config,
      credentials: ssh_core.SshCredentials(
        password: legacy.password,
        privateKey: legacy.privateKey,
      ),
    );
  }
}

/// 将 AppSettings 转换为 AI 的可监听设置 Port。
final class AppAiSettingsAdapter extends ChangeNotifier
    implements ai.AiSettingsPort {
  AppAiSettingsAdapter(this._settings) {
    _settings.addListener(_forwardChange);
  }

  final AppSettings _settings;
  bool _disposed = false;

  @override
  app_core.AppLanguage get language => _settings.language;

  @override
  bool get isEnglish => _settings.isEnglish;

  @override
  bool get ragEnabled => _settings.ragEnabled;

  @override
  String get ragSearchMode => _settings.ragSearchMode;

  @override
  int get ragTopN => _settings.ragTopN;

  @override
  int get sftpDownloadLimitBytes => _settings.sftpDownloadLimitBytes;

  @override
  int get sftpTextEditLimitBytes => _settings.sftpTextEditLimitBytes;

  @override
  Future<void> setRagEnabled(bool value) => _settings.setRagEnabled(value);

  @override
  Future<void> setRagSearchMode(String value) =>
      _settings.setRagSearchMode(value);

  @override
  Future<void> setRagTopN(int value) => _settings.setRagTopN(value);

  @override
  Future<void> setSftpDownloadLimitBytes(int value) =>
      _settings.setSftpDownloadLimitBytes(value);

  @override
  Future<void> setSftpTextEditLimitBytes(int value) =>
      _settings.setSftpTextEditLimitBytes(value);

  void _forwardChange() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(_forwardChange);
    super.dispose();
  }
}

/// 将旧 SSH Service 的会话摘要转换为 AI 的脱敏 Port。
final class AppAiSshAdapter implements ai.AiSshPort {
  const AppAiSshAdapter(this._ssh);

  final SshService _ssh;

  @override
  List<ai.AiSshSessionSnapshot> get sessions =>
      List.unmodifiable(_ssh.sessions.map(_toSnapshot));

  @override
  bool get isConnected => _ssh.isConnected;

  @override
  ai.AiSshOverviewSnapshot get serverOverviewSnapshot =>
      ai.AiSshOverviewSnapshot(
        byConnection: {
          for (final entry in _ssh.serverOverviewSnapshot.byConnection.entries)
            entry.key: ai.AiSshConnectionOverview(
              count: entry.value.count,
              latestState: _toState(entry.value.latestState),
              hasConnected: entry.value.hasConnected,
            ),
        },
        windowCount: _ssh.serverOverviewSnapshot.windowCount,
      );

  @override
  String? get errorMessage => _ssh.errorMessage;

  @override
  ai.AiSshSessionSnapshot? getSession(String sessionId) {
    final session = _ssh.getSession(sessionId);
    return session == null ? null : _toSnapshot(session);
  }

  @override
  Future<String?> openSession(String connectionId, {String? displayName}) =>
      _ssh.openSession(connectionId, displayName: displayName);

  @override
  Future<bool> ensureSessionConnected(String sessionId, String connectionId) =>
      _ssh.ensureSessionConnected(sessionId, connectionId);

  @override
  bool renameSession(String sessionId, String name) =>
      _ssh.renameSession(sessionId, name);

  @override
  Future<String> loadSessionHistoryText(String sessionId) =>
      _ssh.loadSessionHistoryText(sessionId);

  @override
  bool hasConnectedSession(String connectionId) =>
      _ssh.hasConnectedSession(connectionId);

  @override
  ai.AiSshSessionSnapshot? latestSessionForConnection(String connectionId) {
    final session = _ssh.latestSessionForConnection(connectionId);
    return session == null ? null : _toSnapshot(session);
  }

  @override
  int sessionCountForConnection(String connectionId) =>
      _ssh.sessionCountForConnection(connectionId);

  @override
  Future<void> disconnectSession(String sessionId) =>
      _ssh.disconnectSession(sessionId);

  @override
  Future<void> disconnect() => _ssh.disconnect();

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) =>
      _ssh.disconnectSessionsForConnection(connectionId);

  @override
  Future<void> restoreTmuxSessions() => _ssh.restoreTmuxSessions();

  @override
  Future<List<ai.AiTerminalHistorySnapshot>>
  loadTerminalHistoryRecords() async => List.unmodifiable(
    (await _ssh.loadTerminalHistoryRecords()).map(
      (item) => ai.AiTerminalHistorySnapshot(
        sessionId: item.sessionId,
        connectionId: item.connectionId,
        connectionName: item.connectionName,
        displayName: item.displayName,
        state: item.state,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt,
        tmuxSessionName: item.tmuxSessionName,
        errorMessage: item.errorMessage,
      ),
    ),
  );

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) =>
      _ssh.removeTerminalHistoryRecord(sessionId);

  @override
  Future<app_core.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final result = await _ssh.runOneShotCommand(
      connectionId: connectionId,
      command: command,
      timeout: timeout,
    );
    return app_core.RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  ai.AiSshSessionSnapshot _toSnapshot(dynamic session) {
    return ai.AiSshSessionSnapshot(
      id: session.id as String,
      connectionId: session.connectionId as String,
      connectionName: session.connectionName as String,
      displayName: session.displayName as String,
      state: _toState(session.state),
      isConnected: session.isConnected as bool,
      createdAt: session.createdAt as DateTime,
      updatedAt: session.updatedAt as DateTime,
      tmuxSessionName: session.tmuxSessionName as String?,
      tmuxAutoDeleteSeconds: session.tmuxAutoDeleteSeconds as int?,
      errorMessage: session.errorMessage as String?,
      estimatedMemoryBytes: session.estimatedMemoryBytes as int,
    );
  }

  ai.AiSshConnectionState _toState(dynamic state) {
    final name = state?.name;
    return switch (name) {
      'connecting' => ai.AiSshConnectionState.connecting,
      'connected' => ai.AiSshConnectionState.connected,
      'error' => ai.AiSshConnectionState.error,
      _ => ai.AiSshConnectionState.disconnected,
    };
  }
}

/// 将 App SFTP Service 的文件操作转换为 AI Port；正文限制仍由旧服务校验。
final class AppAiSftpAdapter implements ai.AiSftpPort {
  const AppAiSftpAdapter(this._sftp);

  final SftpService _sftp;

  @override
  Future<List<ai.AiSftpEntrySnapshot>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) async => List.unmodifiable(
    (await _sftp.listDirectoryForConnection(connectionId, path)).map(
      (item) => ai.AiSftpEntrySnapshot(
        connectionId: item.connectionId,
        name: item.name,
        path: item.path,
        isDirectory: item.isDirectory,
        isLink: item.isLink,
        size: item.size,
        sizeLabel: item.sizeLabel,
        modifiedAt: item.modifiedAt,
        modifiedLabel: item.modifiedLabel,
      ),
    ),
  );

  @override
  Future<ai.AiSftpPathSnapshot> statPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    final item = await _sftp.statPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return ai.AiSftpPathSnapshot(
      path: item.path,
      isDirectory: item.isDirectory,
      isLink: item.isLink,
      size: item.size,
      sizeLabel: item.sizeLabel,
      modifiedAt: item.modifiedAt,
    );
  }

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = _defaultAiSftpTextEditLimitBytes,
  }) => _sftp.readTextPathForConnection(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = _defaultAiSftpDownloadLimitBytes,
  }) => _sftp.downloadPathForConnection(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = _defaultAiSftpTextEditLimitBytes,
  }) => _sftp.writeTextPathForConnection(
    connectionId: connectionId,
    path: path,
    text: text,
    maxBytes: maxBytes,
  );

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = _defaultAiSftpDownloadLimitBytes,
  }) => _sftp.uploadBytesPathForConnection(
    connectionId: connectionId,
    path: path,
    bytes: bytes,
    maxBytes: maxBytes,
  );

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) => _sftp.createDirectoryPathForConnection(
    connectionId: connectionId,
    path: path,
  );

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) => _sftp.renamePathForConnection(
    connectionId: connectionId,
    path: path,
    newPath: newPath,
  );

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) => _sftp.deletePathForConnection(connectionId: connectionId, path: path);
}

/// 将 Monitoring Module 的公共工具服务接到 AI 的监控 Port。
final class AppAiMonitoringAdapter implements ai.AiMonitoringPort {
  AppAiMonitoringAdapter(monitoring.MonitoringService service)
    : _tools = monitoring.MonitoringToolService(service);

  final monitoring.MonitoringToolService _tools;

  @override
  Future<Map<String, dynamic>> query(app_core.MonitoringQuery request) async {
    final operation = request.operation.trim();
    final args = request.arguments;
    switch (operation) {
      case 'getState':
        return getState();
      case 'getHealth':
        return getHealth(
          connectionIds: (args['connectionIds'] as List?)
              ?.whereType<String>()
              .toList(growable: false),
        );
      case 'getSamples':
        return getSamples(
          request.connectionId ?? '',
          visibleOnly: args['visibleOnly'] as bool? ?? true,
          limit: (args['limit'] as num?)?.toInt() ?? 100,
        );
      case 'getAlerts':
        return getAlerts(limit: (args['limit'] as num?)?.toInt() ?? 50);
      case 'getPorts':
        return getPorts(request.connectionId ?? '');
      case 'getApplications':
        return getApplications(request.connectionId ?? '');
      default:
        throw ArgumentError.value(operation, 'operation');
    }
  }

  @override
  Map<String, dynamic> getState() => _tools.getState();

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) =>
      _tools.setSelectedServers(connectionIds);

  @override
  Map<String, dynamic> clearSelection() => _tools.clearSelection();

  @override
  Future<Map<String, dynamic>> start() => _tools.start();

  @override
  Map<String, dynamic> stop() => _tools.stop();

  @override
  Map<String, dynamic> stopForConnection(String connectionId) =>
      _tools.stopForConnection(connectionId);

  @override
  Map<String, dynamic> setInterval(Duration interval) =>
      _tools.setInterval(interval);

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) =>
      _tools.setHistoryWindow(window);

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) =>
      _tools.getHealth(connectionIds: connectionIds);

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) => _tools.getSamples(connectionId, visibleOnly: visibleOnly, limit: limit);

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) =>
      _tools.getAlerts(limit: limit);

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) =>
      _tools.getPorts(connectionId);

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) =>
      _tools.getApplications(connectionId);

  @override
  Future<Map<String, dynamic>> startWithTargets(
    Map<String, ssh_core.SshTargetBinding> targets,
  ) => _tools.startWithTargets(targets);
}
