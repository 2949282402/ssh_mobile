part of '../ssh_service.dart';

/// Owns session metadata, restoration, and public session acquisition flows.
extension _SshServiceSessionActions on SshService {
  Future<String> _loadSessionHistoryText(String sessionId) {
    return _historyService.readTail(sessionId);
  }

  Future<List<TerminalHistoryRecord>> _loadTerminalHistoryRecords() {
    return _terminalMetadataStore.loadTerminalHistoryRecords().then(
      (records) => records
          .map(
            (record) => TerminalHistoryRecord(
              sessionId: record.sessionId,
              connectionId: record.connectionId,
              connectionName: record.connectionName,
              displayName: record.displayName,
              tmuxSessionName: record.tmuxSessionName,
              state: record.state,
              errorMessage: record.errorMessage,
              createdAt: record.createdAt,
              updatedAt: record.updatedAt,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<void> _removeTerminalHistoryRecord(String sessionId) {
    return _terminalMetadataStore.removeTerminalHistoryRecord(sessionId);
  }

  bool _hasConnectedSession(String connectionId) {
    return _serverOverviewSnapshot.forConnection(connectionId).hasConnected;
  }

  SshSession? _latestSessionForConnection(String connectionId) {
    for (final session in _sessions.values.toList().reversed) {
      if (session.connectionId == connectionId) return session;
    }
    return null;
  }

  int _sessionCountForConnection(String connectionId) {
    return _serverOverviewSnapshot.forConnection(connectionId).count;
  }

  Future<void> _disconnectSessionsForConnection(String connectionId) async {
    final sessionIds = _sessions.values
        .where((session) => session.connectionId == connectionId)
        .map((session) => session.id)
        .toList();

    for (final sessionId in sessionIds) {
      await disconnectSession(sessionId);
    }
  }

  bool _renameSession(String sessionId, String name) {
    final session = _sessions[sessionId];
    final nextName = name.trim();
    if (session == null || nextName.isEmpty) return false;
    if (_isSessionNameTaken(nextName, exceptSessionId: sessionId)) {
      return false;
    }
    session.displayName = nextName;
    _schedulePersistence(
      () => _saveRestorableTmuxSession(session),
      description: 'Failed to save restorable SSH session',
    );
    _notifySessionMetadataChanged();
    return true;
  }

  void _setSessionFontSize(String sessionId, double fontSize) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.fontSize = fontSize.clamp(
      SshSession.minTerminalFontSize,
      SshSession.maxTerminalFontSize,
    );
    _schedulePersistence(
      () => _saveRestorableTmuxSession(session),
      description: 'Failed to save restorable SSH session',
    );
    _notifySessionMetadataChanged();
  }

  Future<void> _restoreTmuxSessions() async {
    if (_restoredTmuxSessions || _shutdownRequested) return;
    _restoredTmuxSessions = true;
    await _terminalMetadataStore.initFuture;
    if (_shutdownRequested) return;
    final storedSessions = await _terminalMetadataStore
        .loadRestorableTmuxSessions();
    if (_shutdownRequested) return;
    AppLogService.instance.info(
      'Restoring tmux sessions',
      details: 'count=${storedSessions.length}',
    );
    if (storedSessions.isEmpty) return;

    for (final stored in storedSessions) {
      if (_shutdownRequested) return;
      final config = _connectionRepository.getConnection(stored.connectionId);
      if (config?.launchMode != TerminalLaunchMode.tmux) {
        AppLogService.instance.warning(
          'Removing stale restorable tmux session',
          details: 'sessionId=${stored.sessionId}',
        );
        await _terminalMetadataStore.removeRestorableTmuxSession(
          stored.sessionId,
        );
        continue;
      }

      _sessions[stored.sessionId] = SshSession(
        id: stored.sessionId,
        connectionId: stored.connectionId,
        connectionName: config!.name,
        displayName: _uniqueSessionName(stored.displayName),
        tmuxSessionName: stored.tmuxSessionName,
        tmuxAutoDeleteSeconds: config.tmuxAutoDeleteSeconds,
        fontSize: stored.fontSize,
        outputController: StreamController<String>.broadcast(),
        state: SshConnectionState.disconnected,
        errorMessage: 'Waiting to reconnect tmux session',
      );
      _lastSessionId = stored.sessionId;
    }

    _refreshSessionsView();
    notify();

    for (final session in _sessions.values.toList()) {
      if (_shutdownRequested) return;
      final config = _connectionRepository.getConnection(session.connectionId);
      if (config?.launchMode != TerminalLaunchMode.tmux ||
          session.isConnected) {
        continue;
      }
      unawaited(connect(session.connectionId, sessionId: session.id));
    }
  }

  Future<String?> _openSession(
    String connectionId, {
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    await ensureInitialized();
    final sessionId = _createSessionId(connectionId);
    AppLogService.instance.info(
      'Opening SSH session',
      details: 'connectionId=$connectionId sessionId=$sessionId',
    );
    await connect(
      connectionId,
      sessionId: sessionId,
      displayName: displayName,
      onUnknownHostKey: onUnknownHostKey,
    );
    final session = _sessions[sessionId];
    if (session?.isConnected == true) return sessionId;

    _lastErrorMessage = session?.errorMessage ?? _lastErrorMessage;
    AppLogService.instance.warning(
      'open SSH session failed',
      details:
          'connectionId=$connectionId sessionId=$sessionId error=$_lastErrorMessage',
    );
    await _removeFailedOpenSession(sessionId);
    return null;
  }

  Future<bool> _ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async {
    await ensureInitialized();
    final existing = _sessions[sessionId];
    if (existing == null || existing.connectionId != connectionId) {
      AppLogService.instance.warning(
        'SSH session reconnect target mismatch',
        details: 'connectionId=$connectionId sessionId=$sessionId',
      );
      return false;
    }
    if (existing.isConnected) {
      _lastSessionId = sessionId;
      return true;
    }

    await connect(connectionId, sessionId: sessionId);
    return _sessions[sessionId]?.isConnected == true;
  }

  Future<bool> _ensureConnected(String connectionId) async {
    final existing = latestSessionForConnection(connectionId);
    if (existing?.isConnected == true) {
      _lastSessionId = existing!.id;
      return true;
    }

    final sessionId = await openSession(connectionId);
    return sessionId != null;
  }
}
