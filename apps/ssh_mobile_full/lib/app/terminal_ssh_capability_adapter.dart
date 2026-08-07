// App 层 SSH Terminal Capability 适配器。
//
// Terminal Package 依赖 ssh_core 的稳定模型，而当前 SSH 实现仍使用旧
// App 内部 SshSession。该适配器只做类型和生命周期桥接，所有真实 SSH
// 连接仍由同一个 SshService Owner 持有。

import 'dart:async';

import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../services/ssh_service.dart';

/// 将旧 SshService 暴露为 ssh_core 的终端能力。
final class AppTerminalSshCapability implements ssh_core.SshTerminalCapability {
  /// 创建适配器并监听旧 Service 的元数据变化。
  AppTerminalSshCapability(this._service) {
    _service.addListener(_onServiceChanged);
  }

  final SshService _service;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _disposed = false;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  List<ssh_core.SshTerminalSession> get sessions =>
      _service.sessions.map(_toSession).toList(growable: false);

  @override
  ssh_core.SshTerminalSession? getSession(String sessionId) {
    final session = _service.getSession(sessionId);
    return session == null ? null : _toSession(session);
  }

  @override
  String? get errorMessage => _service.errorMessage;

  @override
  Future<String> loadSessionHistoryText(String sessionId) {
    return _service.loadSessionHistoryText(sessionId);
  }

  @override
  Future<bool> ensureSessionConnected(String sessionId, String connectionId) {
    return _service.ensureSessionConnected(sessionId, connectionId);
  }

  @override
  void setSessionFontSize(String sessionId, double fontSize) {
    _service.setSessionFontSize(sessionId, fontSize);
  }

  @override
  void sendData(String sessionId, String data) {
    _service.sendData(sessionId, data);
  }

  @override
  void resizeTerminal(String sessionId, int width, int height) {
    _service.resizeTerminal(sessionId, width, height);
  }

  @override
  Future<void> disconnectSession(String sessionId) {
    return _service.disconnectSession(sessionId);
  }

  @override
  Future<void> disconnect() => _service.disconnect();

  @override
  bool isSessionNameAvailable(String name) =>
      _service.isSessionNameAvailable(name);

  @override
  bool renameSession(String sessionId, String name) {
    return _service.renameSession(sessionId, name);
  }

  @override
  Future<String?> openSession(String connectionId, {String? displayName}) {
    return _service.openSession(connectionId, displayName: displayName);
  }

  @override
  Future<bool> ensureConnected(String connectionId) {
    return _service.ensureConnected(connectionId);
  }

  /// 停止监听旧 Service 并关闭适配器通知流。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _service.removeListener(_onServiceChanged);
    await _changes.close();
  }

  void _onServiceChanged() {
    if (!_disposed && !_changes.isClosed) _changes.add(null);
  }

  ssh_core.SshTerminalSession _toSession(SshSession session) {
    return ssh_core.SshTerminalSession(
      id: session.id,
      connectionId: session.connectionId,
      connectionName: session.connectionName,
      displayName: session.displayName,
      tmuxSessionName: session.tmuxSessionName,
      tmuxAutoDeleteSeconds: session.tmuxAutoDeleteSeconds,
      fontSize: session.fontSize,
      state: ssh_core.SshConnectionState.values.byName(session.state.name),
      errorMessage: session.errorMessage,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      output: session.output,
      outputText: session.outputText,
      estimatedMemoryBytes: session.estimatedMemoryBytes,
    );
  }
}

/// 只注入一个 SshSessionManager 的 Terminal-facing App Scope 包装器。
final class AppTerminalSshSessionManager implements ssh_core.SshSessionManager {
  /// 创建包装器；底层 SSH Owner 由 [service] 持有。
  AppTerminalSshSessionManager(this.service)
    : terminal = AppTerminalSshCapability(service);

  /// 旧 SSH Service；仅在 App Composition Root 使用。
  final SshService service;

  /// Terminal Capability 的唯一 App Scope 实例。
  final AppTerminalSshCapability terminal;

  @override
  ssh_core.SshTerminalCapability get terminalCapability => terminal;

  @override
  bool get initialized => service.initialized;

  @override
  Future<void> ensureInitialized() => service.ensureInitialized();

  @override
  Future<ssh_core.SshSessionLease> acquire({
    required String sessionId,
    required Future<ssh_core.SshSession> Function() create,
  }) {
    return service.acquire(sessionId: sessionId, create: create);
  }

  @override
  Future<void> close() async {
    try {
      await service.close();
    } finally {
      await terminal.dispose();
    }
  }
}
