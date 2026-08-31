part of '../ssh_service.dart';

/// Owns terminal input/output and one-shot command execution for sessions.
extension _SshServiceCommands on SshService {
  Future<void> _disconnectSession(String sessionId) async {
    AppLogService.instance.info(
      'Disconnecting session',
      details: 'sessionId=$sessionId',
    );
    _closingSessionIds.add(sessionId);
    if (_usesBackgroundForSession(sessionId)) {
      _backgroundService.invoke('sshDisconnect', {'sessionId': sessionId});
    } else {
      await _closeLocalSession(sessionId, destroyTmux: true);
    }
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.state = SshConnectionState.disconnected;
      session.errorMessage = 'Closed by user';
      session.updatedAt = DateTime.now();
      await _terminateSessionTelemetry(session);
      _schedulePersistence(
        () => _saveTerminalHistoryRecord(session),
        description: 'Failed to save terminal history record',
      );
    }
    await session?.close();
    await _terminalMetadataStore.removeRestorableTmuxSession(sessionId);
    _sessionTargetBindings.remove(sessionId);
    _sessionUsesBackgroundService.remove(sessionId);
    final pendingConnect = _connectCompleters.remove(sessionId);
    if (pendingConnect != null && !pendingConnect.isCompleted) {
      pendingConnect.complete();
    }
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
    await _stopServiceIfIdle();
    _refreshSessionsView();
    _notifySessionMetadataChanged();
  }

  Future<void> _removeFailedOpenSession(String sessionId) async {
    _closingSessionIds.add(sessionId);
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.state = SshConnectionState.error;
      session.errorMessage ??= 'Connection failed';
      session.updatedAt = DateTime.now();
      _schedulePersistence(
        () => _saveTerminalHistoryRecord(session),
        description: 'Failed to save terminal history record',
      );
    }
    await session?.close();
    await _terminalMetadataStore.removeRestorableTmuxSession(sessionId);
    _sessionTargetBindings.remove(sessionId);
    _sessionUsesBackgroundService.remove(sessionId);
    _connectCompleters.remove(sessionId);
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
    await _stopServiceIfIdle();
    _refreshSessionsView();
    _notifySessionMetadataChanged();
  }

  Future<void> _disconnectAll() async {
    AppLogService.instance.info(
      'Disconnecting all sessions',
      details: 'count=${_sessions.length}',
    );
    _closingSessionIds.addAll(_sessions.keys);
    if (_sessionUsesBackgroundService.values.any((uses) => uses)) {
      _backgroundService.invoke('sshDisconnectAll');
    }
    for (final sessionId in _sessions.keys.toList()) {
      if (!_usesBackgroundForSession(sessionId)) {
        await _closeLocalSession(sessionId, destroyTmux: true);
      }
    }
    for (final session in _sessions.values) {
      session.state = SshConnectionState.disconnected;
      session.errorMessage = 'Closed by user';
      session.updatedAt = DateTime.now();
      _schedulePersistence(
        () => _saveTerminalHistoryRecord(session),
        description: 'Failed to save terminal history record',
      );
      await session.close();
    }
    _sessions.clear();
    _sessionTargetBindings.clear();
    _sessionUsesBackgroundService.clear();
    _backgroundOverviewSnapshot = null;
    _refreshSessionsView();
    for (final completer in _connectCompleters.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _connectCompleters.clear();
    _lastSessionId = null;
    await _terminalMetadataStore.clearRestorableTmuxSessions();
    await BackgroundServiceManager.stop();
    notify();
  }

  void _resizeTerminal(String sessionId, int width, int height) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      if (_usesBackgroundForSession(sessionId)) {
        _backgroundService.invoke('sshResize', {
          'sessionId': sessionId,
          'width': width,
          'height': height,
        });
      } else {
        _localRuntimes[sessionId]?.shell.resizeTerminal(width, height);
      }
    }
  }

  void _sendData(String sessionId, String data) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      if (_usesBackgroundForSession(sessionId)) {
        _backgroundService.invoke('sshInput', {
          'sessionId': sessionId,
          'data': data,
        });
      } else {
        _localRuntimes[sessionId]?.shell.stdin.add(utf8.encode(data));
      }
    }
  }

  void _sendBytes(String sessionId, Uint8List data) {
    sendData(sessionId, String.fromCharCodes(data));
  }

  /// 执行单次 SSH 命令并返回结果。
  /// AI 工具和诊断场景使用此方法，通过普通 SSH exec 执行（非 tmux）。
  /// 不复用交互式终端会话，每条命令独立连接，用完即关。
  Future<RemoteCommandResult> _runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _trackOwnedSshOperation(() async {
      final target = await RemoteTargetScope.resolveIfBound(
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
        connectionId: connectionId,
      );
      return _runOneShotCommandForTarget(
        target: target,
        command: command,
        timeout: timeout,
        onUnknownHostKey: onUnknownHostKey,
      );
    });
  }

  /// Executes against an explicitly approved target binding.
  ///
  /// Long-running Playbooks should call this for every step so a connection
  /// edit between steps stops execution instead of silently changing servers.
  Future<RemoteCommandResult> _runOneShotCommandForBinding({
    required ConnectionTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _trackOwnedSshOperation(() async {
      final target = await RemoteTargetScope.resolveBinding(
        binding,
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
      );
      if (target == null) {
        if (_connectionRepository.getConnection(binding.id) == null) {
          throw RemoteTargetScopeException.notFound(binding.id);
        }
        throw RemoteTargetScopeException.targetChanged(binding.id);
      }
      return _runOneShotCommandForTarget(
        target: target,
        command: command,
        timeout: timeout,
        onUnknownHostKey: onUnknownHostKey,
      );
    });
  }
}
