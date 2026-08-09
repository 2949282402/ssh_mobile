// AI Feature 的 App Shell 适配层。
//
// 这里仅把 AppRuntime 已经拥有的设置、AI Storage、SSH、SFTP 和监控实例
// 转换为 feature_ai 的 Port。适配器不创建第二份连接、数据库或 Timer，
// AI 的业务编排仍由 feature_ai Package 负责。

import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';

export '../services/ai_storage_adapter.dart';

// AI 工具的默认传输限制属于 AI Port 合约；App 适配层保留同样的默认值，
// 避免为了读取默认配置重新依赖 Package 内部兼容实现。
const int _defaultAiSftpDownloadLimitBytes = 50 * 1024 * 1024;
const int _defaultAiSftpTextEditLimitBytes = 2 * 1024 * 1024;

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

  ai.AiSshSessionSnapshot _toSnapshot(SshSession session) {
    return ai.AiSshSessionSnapshot(
      id: session.id,
      connectionId: session.connectionId,
      connectionName: session.connectionName,
      displayName: session.displayName,
      state: _toState(session.state),
      isConnected: session.isConnected,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      tmuxSessionName: session.tmuxSessionName,
      tmuxAutoDeleteSeconds: session.tmuxAutoDeleteSeconds,
      errorMessage: session.errorMessage,
      estimatedMemoryBytes: session.estimatedMemoryBytes,
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
