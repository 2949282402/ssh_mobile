// AI 工具测试适配器。
//
// 旧测试夹具仍实现 App Shell 的 Adapter 接口；这些适配器只存在于测试边界，
// 将旧模型转换为 feature_ai 的公开 Port，避免为了迁移测试而放宽生产 API。

import 'dart:typed_data';

import 'package:app_core/app_core.dart' as app_core;
import 'package:connection_core/connection_core.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as playbook;
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'package:ssh_mobile/services/client_system_tool_service.dart'
    as legacy_system;
import 'package:ssh_mobile/services/client_health_advisor.dart'
    as legacy_health;
import 'package:feature_webview/feature_webview.dart' as webview;
import 'package:ssh_mobile/services/connection_target_binding.dart'
    as legacy_binding;
import 'package:ssh_mobile/services/server_catalog_service.dart'
    as legacy_catalog;
import 'package:ssh_mobile/services/server_diagnostics_service.dart'
    as legacy_diagnostics;
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' as legacy_sftp;
import 'package:ssh_mobile/services/ssh_service.dart' as legacy_ssh;
import 'test_storage_adapter.dart';
import 'package:ssh_mobile/services/app_settings.dart' as legacy_settings;
import 'ai_port_adapters.dart' as ports;

/// 将旧 App 工具适配器组合成 AI Tool Service。
ai.AiToolService createAiToolServiceFromLegacy({
  required Object storageService,
  required Object sshService,
  required Object sftpService,
  Object? clientSystemToolService,
  Object? clientHealthAdvisor,
  Object? clientWebViewService,
  Object? serverCatalogService,
  Object? performanceMonitorToolService,
  Object? serverDiagnosticsService,
  Object? appSettings,
  playbook.PlaybookAutomationPort? playbookService,
  String? clientWebViewSessionId,
  List<ai.AiToolProvider>? providers,
}) {
  // 旧测试只传入 ClientSystem Adapter；恢复旧 AiToolService 的默认语义，
  // 让运行时健康检查继续读取同一个测试设备状态，而不是回退到单例。
  var resolvedHealthAdvisor = clientHealthAdvisor;
  if (resolvedHealthAdvisor == null &&
      clientSystemToolService is legacy_system.ClientSystemToolAdapter) {
    resolvedHealthAdvisor = legacy_health.ClientHealthAdvisor(
      clientSystemToolService: clientSystemToolService,
    );
  }
  return ai.AiToolService(
    providers: providers,
    storageService: ports.aiStoragePort(storageService as TestStorageAdapter),
    sshService: _sshPort(sshService),
    sftpService: _sftpPort(sftpService),
    clientSystemToolService: clientSystemToolService == null
        ? null
        : _clientSystemPort(clientSystemToolService),
    clientHealthAdvisor: resolvedHealthAdvisor == null
        ? null
        : ports.aiHealthPort(
            resolvedHealthAdvisor as legacy_health.ClientHealthAdvisorAdapter,
          ),
    clientWebViewService: clientWebViewService == null
        ? null
        : _webViewPort(clientWebViewService),
    serverCatalogService: serverCatalogService == null
        ? null
        : _serverCatalogPort(serverCatalogService),
    performanceMonitorToolService: performanceMonitorToolService == null
        ? null
        : _monitoringPort(performanceMonitorToolService),
    serverDiagnosticsService: serverDiagnosticsService == null
        ? null
        : _diagnosticsPort(serverDiagnosticsService),
    appSettings: appSettings == null
        ? null
        : ports.aiSettingsPort(appSettings as legacy_settings.AppSettings),
    playbookService: playbookService,
    clientWebViewSessionId: clientWebViewSessionId,
  );
}

ai.AiSshPort _sshPort(Object value) {
  if (value is ai.AiSshPort) return value;
  if (value is legacy_ssh.SshService) return ports.aiSshPort(value);
  if (value is legacy_ssh.SshClientAdapter) return _LegacySshPort(value);
  throw ArgumentError.value(value, 'sshService');
}

ai.AiSftpPort _sftpPort(Object value) {
  if (value is ai.AiSftpPort) return value;
  if (value is legacy_sftp.SftpService) return ports.aiSftpPort(value);
  if (value is legacy_sftp.SftpClientAdapter) return _LegacySftpPort(value);
  throw ArgumentError.value(value, 'sftpService');
}

ai.AiClientSystemPort _clientSystemPort(Object value) {
  if (value is ai.AiClientSystemPort) return value;
  if (value is legacy_system.ClientSystemToolAdapter) {
    return _LegacyClientSystemPort(value);
  }
  throw ArgumentError.value(value, 'clientSystemToolService');
}

ai.AiWebViewPort _webViewPort(Object value) {
  if (value is ai.AiWebViewPort) return value;
  if (value is webview.ClientWebViewAdapter) {
    return _LegacyWebViewPort(value);
  }
  throw ArgumentError.value(value, 'clientWebViewService');
}

ai.AiServerCatalogPort _serverCatalogPort(Object value) {
  if (value is ai.AiServerCatalogPort) return value;
  if (value is legacy_catalog.ServerCatalogAdapter) {
    return _LegacyServerCatalogPort(value);
  }
  throw ArgumentError.value(value, 'serverCatalogService');
}

ai.AiMonitoringPort _monitoringPort(Object value) {
  if (value is ai.AiMonitoringPort) return value;
  if (value is monitoring.MonitoringService) {
    return ports.aiMonitoringPort(value);
  }
  throw ArgumentError.value(value, 'performanceMonitorToolService');
}

ai.AiServerDiagnosticsPort _diagnosticsPort(Object value) {
  if (value is ai.AiServerDiagnosticsPort) return value;
  if (value is legacy_diagnostics.ServerDiagnosticsAdapter) {
    return _LegacyDiagnosticsPort(value);
  }
  throw ArgumentError.value(value, 'serverDiagnosticsService');
}

final class _LegacySshPort implements ai.AiSshPort {
  const _LegacySshPort(this._delegate);

  final legacy_ssh.SshClientAdapter _delegate;

  ai.AiSshConnectionState _state(legacy_ssh.SshConnectionState value) =>
      switch (value) {
        legacy_ssh.SshConnectionState.disconnected =>
          ai.AiSshConnectionState.disconnected,
        legacy_ssh.SshConnectionState.connecting =>
          ai.AiSshConnectionState.connecting,
        legacy_ssh.SshConnectionState.connected =>
          ai.AiSshConnectionState.connected,
        legacy_ssh.SshConnectionState.error => ai.AiSshConnectionState.error,
      };

  ai.AiSshSessionSnapshot _session(legacy_ssh.SshSession value) =>
      ai.AiSshSessionSnapshot(
        id: value.id,
        connectionId: value.connectionId,
        connectionName: value.connectionName,
        displayName: value.displayName,
        state: _state(value.state),
        isConnected: value.isConnected,
        createdAt: value.createdAt,
        updatedAt: value.updatedAt,
        tmuxSessionName: value.tmuxSessionName,
        tmuxAutoDeleteSeconds: value.tmuxAutoDeleteSeconds,
        errorMessage: value.errorMessage,
        estimatedMemoryBytes: value.estimatedMemoryBytes,
      );

  @override
  List<ai.AiSshSessionSnapshot> get sessions =>
      _delegate.sessions.map(_session).toList(growable: false);

  @override
  bool get isConnected => _delegate.isConnected;

  @override
  ai.AiSshOverviewSnapshot get serverOverviewSnapshot =>
      ai.AiSshOverviewSnapshot(
        byConnection: {
          for (final entry
              in _delegate.serverOverviewSnapshot.byConnection.entries)
            entry.key: ai.AiSshConnectionOverview(
              count: entry.value.count,
              latestState: entry.value.latestState == null
                  ? null
                  : _state(entry.value.latestState!),
              hasConnected: entry.value.hasConnected,
            ),
        },
        windowCount: _delegate.serverOverviewSnapshot.windowCount,
      );

  @override
  String? get errorMessage => _delegate.errorMessage;

  @override
  ai.AiSshSessionSnapshot? getSession(String sessionId) {
    final value = _delegate.getSession(sessionId);
    return value == null ? null : _session(value);
  }

  @override
  Future<String?> openSession(String connectionId, {String? displayName}) =>
      _delegate.openSession(connectionId, displayName: displayName);

  @override
  Future<bool> ensureSessionConnected(String sessionId, String connectionId) =>
      _delegate.ensureSessionConnected(sessionId, connectionId);

  @override
  bool renameSession(String sessionId, String name) =>
      _delegate.renameSession(sessionId, name);

  @override
  Future<String> loadSessionHistoryText(String sessionId) =>
      _delegate.loadSessionHistoryText(sessionId);

  @override
  bool hasConnectedSession(String connectionId) =>
      _delegate.hasConnectedSession(connectionId);

  @override
  ai.AiSshSessionSnapshot? latestSessionForConnection(String connectionId) {
    final value = _delegate.latestSessionForConnection(connectionId);
    return value == null ? null : _session(value);
  }

  @override
  int sessionCountForConnection(String connectionId) =>
      _delegate.sessionCountForConnection(connectionId);

  @override
  Future<void> disconnectSession(String sessionId) =>
      _delegate.disconnectSession(sessionId);

  @override
  Future<void> disconnect() => _delegate.disconnect();

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) =>
      _delegate.disconnectSessionsForConnection(connectionId);

  @override
  Future<void> restoreTmuxSessions() => _delegate.restoreTmuxSessions();

  @override
  Future<List<ai.AiTerminalHistorySnapshot>>
  loadTerminalHistoryRecords() async {
    final records = await _delegate.loadTerminalHistoryRecords();
    return records
        .map(
          (record) => ai.AiTerminalHistorySnapshot(
            sessionId: record.sessionId,
            connectionId: record.connectionId,
            connectionName: record.connectionName,
            displayName: record.displayName,
            state: record.state,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            tmuxSessionName: record.tmuxSessionName,
            errorMessage: record.errorMessage,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) =>
      _delegate.removeTerminalHistoryRecord(sessionId);

  @override
  Future<app_core.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final result = await _delegate.runOneShotCommand(
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
}

final class _LegacySftpPort implements ai.AiSftpPort {
  const _LegacySftpPort(this._delegate);

  final legacy_sftp.SftpClientAdapter _delegate;

  ai.AiSftpEntrySnapshot _entry(legacy_sftp.SftpEntry value) =>
      ai.AiSftpEntrySnapshot(
        connectionId: value.connectionId,
        name: value.name,
        path: value.path,
        isDirectory: value.isDirectory,
        isLink: value.isLink,
        size: value.size,
        sizeLabel: value.sizeLabel,
        modifiedAt: value.modifiedAt,
        modifiedLabel: value.modifiedLabel,
      );

  ai.AiSftpPathSnapshot _path(legacy_sftp.SftpPathInfo value) =>
      ai.AiSftpPathSnapshot(
        path: value.path,
        isDirectory: value.isDirectory,
        isLink: value.isLink,
        size: value.size,
        sizeLabel: value.sizeLabel,
        modifiedAt: value.modifiedAt,
      );

  @override
  Future<List<ai.AiSftpEntrySnapshot>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) async => (await _delegate.listDirectoryForConnection(
    connectionId,
    path,
  )).map(_entry).toList(growable: false);

  @override
  Future<ai.AiSftpPathSnapshot> statPathForConnection({
    required String connectionId,
    required String path,
  }) async => _path(
    await _delegate.statPathForConnection(
      connectionId: connectionId,
      path: path,
    ),
  );

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = 2 * 1024 * 1024,
  }) => _delegate.readTextPathForConnection(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = 50 * 1024 * 1024,
  }) => _delegate.downloadPathForConnection(
    connectionId: connectionId,
    path: path,
    maxBytes: maxBytes,
  );

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = 2 * 1024 * 1024,
  }) => _delegate.writeTextPathForConnection(
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
    int maxBytes = 50 * 1024 * 1024,
  }) => _delegate.uploadBytesPathForConnection(
    connectionId: connectionId,
    path: path,
    bytes: bytes,
    maxBytes: maxBytes,
  );

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) => _delegate.createDirectoryPathForConnection(
    connectionId: connectionId,
    path: path,
  );

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) => _delegate.renamePathForConnection(
    connectionId: connectionId,
    path: path,
    newPath: newPath,
  );

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) =>
      _delegate.deletePathForConnection(connectionId: connectionId, path: path);
}

final class _LegacyClientSystemPort implements ai.AiClientSystemPort {
  const _LegacyClientSystemPort(this._delegate);

  final legacy_system.ClientSystemToolAdapter _delegate;

  @override
  Map<String, dynamic> getClientTime() => _delegate.getClientTime();
  @override
  Map<String, dynamic> getClientDeviceInfo() => _delegate.getClientDeviceInfo();
  @override
  Future<Map<String, dynamic>> getNetworkInfo() => _delegate.getNetworkInfo();
  @override
  Future<Map<String, dynamic>> getBatteryStatus() =>
      _delegate.getBatteryStatus();
  @override
  Future<Map<String, dynamic>> getPermissionStatus() =>
      _delegate.getPermissionStatus();
  @override
  Future<Map<String, dynamic>> openAppSettings() => _delegate.openAppSettings();
  @override
  Future<Map<String, dynamic>> setClipboard(String text) =>
      _delegate.setClipboard(text);
  @override
  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm = true,
  }) => _delegate.setAlarm(
    triggerAt: triggerAt,
    delaySeconds: delaySeconds,
    delayMinutes: delayMinutes,
    label: label,
    useSystemAlarm: useSystemAlarm,
  );
  @override
  Future<Map<String, dynamic>> listAlarms() => _delegate.listAlarms();
  @override
  Future<Map<String, dynamic>> cancelAlarm(String alarmId) =>
      _delegate.cancelAlarm(alarmId);
  @override
  Future<Map<String, dynamic>> queryLogs({
    String? level,
    String? contains,
    int limit = 50,
  }) => _delegate.queryLogs(level: level, contains: contains, limit: limit);
  @override
  Future<Map<String, dynamic>> getLogCounts() => _delegate.getLogCounts();
  @override
  Future<Map<String, dynamic>> deleteLogEntries(List<int> ids) =>
      _delegate.deleteLogEntries(ids);
  @override
  Future<Map<String, dynamic>> clearLogs() => _delegate.clearLogs();
  @override
  Future<Map<String, dynamic>> saveBytesToFile({
    required String fileName,
    required List<int> bytes,
    String? dialogTitle,
  }) => _delegate.saveBytesToFile(
    fileName: fileName,
    bytes: bytes,
    dialogTitle: dialogTitle,
  );
  @override
  Future<ai.AiPickedFile?> pickFile({
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) async {
    final value = await _delegate.pickFile(
      allowedExtensions: allowedExtensions,
      dialogTitle: dialogTitle,
    );
    return value == null
        ? null
        : ai.AiPickedFile(
            name: value.name,
            bytes: value.bytes,
            localPath: value.localPath,
          );
  }
}

final class _LegacyWebViewPort implements ai.AiWebViewPort {
  const _LegacyWebViewPort(this._delegate);

  final webview.ClientWebViewAdapter _delegate;

  ai.AiWebViewStateSnapshot _state(webview.ClientWebViewStateSnapshot value) =>
      ai.AiWebViewStateSnapshot(
        chatId: value.chatId,
        supported: value.supported,
        hasPage: value.hasPage,
        progress: value.progress,
        isLoading: value.isLoading,
        isAiBrowsing: value.isAiBrowsing,
        canGoBack: value.canGoBack,
        canGoForward: value.canGoForward,
        lastTextLength: value.lastTextLength,
        lastTextTruncated: value.lastTextTruncated,
        url: value.url,
        title: value.title,
        aiBrowsingLabel: value.aiBrowsingLabel,
        aiBrowsingStartedAt: value.aiBrowsingStartedAt,
        lastError: value.lastError,
        lastTextCapturedAt: value.lastTextCapturedAt,
        updatedAt: value.updatedAt,
        error: value.error,
      );

  @override
  Future<ai.AiWebViewSnapshot> readPlainText(
    String chatId, {
    int maxChars = ai.aiWebViewDefaultMaxChars,
  }) async {
    final value = await _delegate.readPlainText(chatId, maxChars: maxChars);
    return ai.AiWebViewSnapshot(
      chatId: value.chatId,
      supported: value.supported,
      hasPage: value.hasPage,
      text: value.text,
      textLength: value.textLength,
      maxChars: value.maxChars,
      truncated: value.truncated,
      blocked: value.blocked,
      sensitiveFormDetected: value.sensitiveFormDetected,
      url: value.url,
      title: value.title,
      capturedAt: value.capturedAt,
      error: value.error,
    );
  }

  @override
  Future<ai.AiWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
    String? engine,
  }) async {
    final value = await _delegate.searchWeb(
      chatId,
      query,
      maxResults: maxResults,
      engine: engine,
    );
    return ai.AiWebViewSearchResult(
      chatId: value.chatId,
      supported: value.supported,
      query: value.query,
      engine: value.engine,
      searchUrl: value.searchUrl,
      title: value.title,
      results: value.results
          .map(
            (item) => ai.AiWebViewSearchItem(
              title: item.title,
              url: item.url,
              snippet: item.snippet,
            ),
          )
          .toList(growable: false),
      capturedAt: value.capturedAt,
      error: value.error,
    );
  }

  @override
  Future<ai.AiWebViewStateSnapshot> getState(String chatId) async =>
      _state(await _delegate.getState(chatId));

  @override
  Future<ai.AiWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  }) async {
    final value = await _delegate.navigate(
      chatId,
      action: action,
      input: input,
    );
    return ai.AiWebViewNavigationResult(
      chatId: value.chatId,
      supported: value.supported,
      action: value.action,
      input: value.input,
      navigated: value.navigated,
      blocked: value.blocked,
      error: value.error,
      state: value.state == null ? null : _state(value.state!),
    );
  }

  @override
  void interruptAiBrowsing(String chatId) =>
      _delegate.interruptAiBrowsing(chatId);

  @override
  void clearSession(String chatId) => _delegate.clearSession(chatId);
}

final class _LegacyServerCatalogPort implements ai.AiServerCatalogPort {
  const _LegacyServerCatalogPort(this._delegate);

  final legacy_catalog.ServerCatalogAdapter _delegate;

  @override
  List<Map<String, dynamic>> listServerSummaries() =>
      _delegate.listServerSummaries();

  @override
  Map<String, dynamic>? getServerDetails(String connectionId) =>
      _delegate.getServerDetails(connectionId);

  @override
  ConnectionConfig buildUpdateCandidate(
    ConnectionConfig current,
    Map<String, dynamic> changes,
  ) {
    var next = ConnectionConfig.fromJson(current.toJson());
    for (final entry in changes.entries) {
      next = switch (entry.key) {
        'name' => next.copyWith(name: entry.value as String?),
        'host' => next.copyWith(host: entry.value as String?),
        'port' => next.copyWith(port: (entry.value as num?)?.toInt()),
        'username' => next.copyWith(username: entry.value as String?),
        'group' => next.copyWith(group: entry.value as String?),
        'tmuxAutoDeleteSeconds' => next.copyWith(
          tmuxAutoDeleteSeconds: (entry.value as num?)?.toInt(),
        ),
        _ => next,
      };
    }
    return next;
  }

  @override
  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
    ssh_core.SshTargetBinding? approvedTarget,
    ConnectionConfig? approvedCurrent,
    ConnectionConfig? approvedCandidate,
  }) => _delegate.updateServerMetadata(
    connectionId: connectionId,
    changes: changes,
    approvedTarget: approvedTarget == null
        ? null
        : legacy_binding.ConnectionTargetBinding.fromConfig(
            approvedTarget.config,
          ),
    approvedCurrent: approvedCurrent,
    approvedCandidate: approvedCandidate,
  );

  @override
  Future<Map<String, dynamic>> deleteServer(String connectionId) =>
      _delegate.deleteServer(connectionId);

  @override
  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds) =>
      _delegate.reorderServers(orderedIds);
}

final class _LegacyDiagnosticsPort implements ai.AiServerDiagnosticsPort {
  const _LegacyDiagnosticsPort(this._delegate);

  final legacy_diagnostics.ServerDiagnosticsAdapter _delegate;

  @override
  Future<Map<String, dynamic>> detectOs(String connectionId) =>
      _delegate.detectOs(connectionId);
  @override
  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  }) => _delegate.getStatus(connectionId: connectionId, mode: mode);
  @override
  Future<Map<String, dynamic>> generateOpsReport(String connectionId) =>
      _delegate.generateOpsReport(connectionId);
}
