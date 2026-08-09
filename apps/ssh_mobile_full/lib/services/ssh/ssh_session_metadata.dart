part of '../ssh_service.dart';

extension SshSessionMetadataActions on SshService {
  void _notifySessionMetadataChanged() {
    _refreshSessionsView();
    notify();
  }

  String _createSessionId(String connectionId) {
    return '$connectionId-${DateTime.now().millisecondsSinceEpoch}-${_random.nextInt(10000)}';
  }

  String _defaultDisplayName(String host, String connectionId) {
    final count = sessionCountForConnection(connectionId);
    return count == 0 ? host : '$host (${count + 1})';
  }

  String defaultDisplayNameForConnection(String connectionId) {
    final config = _connectionRepository.getConnection(connectionId);
    return _defaultDisplayName(config?.name ?? 'SSH', connectionId);
  }

  bool isSessionNameAvailable(String name) {
    return name.trim().isNotEmpty && !_isSessionNameTaken(name);
  }

  bool _isSessionNameTaken(String name, {String? exceptSessionId}) {
    final normalizedName = name.trim().toLowerCase();
    return _sessions.values.any(
      (session) =>
          session.id != exceptSessionId &&
          session.displayName.trim().toLowerCase() == normalizedName,
    );
  }

  String _uniqueSessionName(String baseName) {
    final normalizedBaseName = baseName.trim();
    if (!_isSessionNameTaken(normalizedBaseName)) return normalizedBaseName;

    var index = 2;
    while (true) {
      final candidate = '$normalizedBaseName ($index)';
      if (!_isSessionNameTaken(candidate)) return candidate;
      index++;
    }
  }

  String _uniqueTmuxSessionName(
    String baseName, {
    required String exceptSessionId,
  }) {
    bool exists(String name) {
      return _sessions.values.any(
        (session) =>
            session.id != exceptSessionId &&
            session.tmuxSessionName != null &&
            session.tmuxSessionName!.toLowerCase() == name.toLowerCase(),
      );
    }

    final normalized = baseName.trim().replaceAll(RegExp(r'\s+'), '_');
    if (!exists(normalized)) return normalized;

    var index = 2;
    while (true) {
      final candidate = '${normalized}_$index';
      if (!exists(candidate)) return candidate;
      index++;
    }
  }

  String _tmuxSessionNameForSession(SshSession session) {
    return 'ssh_mobile_${session.connectionName.replaceAll(RegExp(r'\W+'), '_').toLowerCase()}';
  }

  TerminalLaunchMode _effectiveLaunchMode(ConnectionConfig config) {
    if (config.launchMode == TerminalLaunchMode.tmux &&
        config.serverPlatform == ServerPlatform.windows) {
      AppLogService.instance.warning(
        'Windows server platform does not support tmux. Downgrading to plain SSH.',
        details: 'connection=${config.name}',
      );
      return TerminalLaunchMode.ssh;
    }
    return config.launchMode;
  }

  Future<void> _saveRestorableTmuxSession(SshSession session) async {
    if (session.tmuxSessionName == null) return;
    await _terminalMetadataStore.saveRestorableTmuxSession(
      terminal_metadata.RestorableTmuxSession(
        sessionId: session.id,
        connectionId: session.connectionId,
        displayName: session.displayName,
        tmuxSessionName: session.tmuxSessionName!,
        fontSize: session.fontSize,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _saveTerminalHistoryRecord(SshSession session) async {
    await _terminalMetadataStore.saveTerminalHistoryRecord(
      terminal_metadata.TerminalHistoryRecord(
        sessionId: session.id,
        connectionId: session.connectionId,
        connectionName: session.connectionName,
        displayName: session.displayName,
        tmuxSessionName: session.tmuxSessionName,
        state: session.state.name,
        errorMessage: session.errorMessage,
        createdAt: session.createdAt,
        updatedAt: DateTime.now(),
      ),
    );
  }

  void _setSessionError(
    String sessionId,
    String connectionId,
    String connectionName,
    String message,
  ) {
    final session = _sessions.putIfAbsent(
      sessionId,
      () => SshSession(
        id: sessionId,
        connectionId: connectionId,
        connectionName: connectionName,
        outputController: StreamController<String>.broadcast(),
      ),
    );
    session.state = SshConnectionState.error;
    session.errorMessage = message;
    session.updatedAt = DateTime.now();
    _lastErrorMessage = message;
    _notifySessionMetadataChanged();

    final completer = _connectCompleters.remove(sessionId);
    completer?.completeError(StateError(message));
  }

  String _notificationSummary() {
    final active = _sessions.values.where((s) => s.isConnected).toList();
    if (active.isEmpty) return 'No active SSH connections';
    if (active.length == 1) {
      return _appSettings?.showServerNamesInNotifications == true
          ? active.first.displayName
          : '1 SSH session';
    }
    return '${active.length} active SSH connections';
  }

  Future<void> _stopServiceIfIdle() async {
    final hasActive = _sessions.values.any(
      (session) =>
          session.state == SshConnectionState.connected ||
          session.state == SshConnectionState.connecting,
    );
    if (!hasActive) {
      await BackgroundServiceManager.stop();
    } else {
      BackgroundServiceManager.updateStatus(_notificationSummary());
    }
  }
}
