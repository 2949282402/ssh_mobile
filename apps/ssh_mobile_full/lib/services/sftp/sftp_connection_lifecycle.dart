part of 'sftp_service_io.dart';

extension _SftpConnectionLifecycle on SftpService {
  Future<void> _connectForConnection(
    String connectionId, {
    dynamic onUnknownHostKey,
  }) async {
    ConnectionRuntimeTarget runtimeTarget;
    try {
      runtimeTarget = await RemoteTargetScope.resolveIfBound(
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
        connectionId: connectionId,
      );
    } on RemoteTargetScopeException catch (e) {
      _activeConnectionId = connectionId;
      final session = _sessions.putIfAbsent(
        connectionId,
        () => _SftpSession(
          connectionId: connectionId,
          connectionName: connectionId,
          currentPath: _lastPaths[connectionId] ?? '.',
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = e.message;
      notifyListeners();
      return;
    }
    final config = runtimeTarget.config;

    var existing = _sessions[connectionId];
    if (existing != null &&
        existing.targetBinding?.fingerprint !=
            runtimeTarget.binding.fingerprint) {
      existing.close();
      _sessions.remove(connectionId);
      existing = null;
    }
    if (existing?.sftp != null) {
      _activeConnectionId = connectionId;
      notifyListeners();
      return;
    }
    if (existing?.state == SftpConnectionState.connecting) {
      _activeConnectionId = connectionId;
      notifyListeners();
      final task = _connectTasks[connectionId];
      if (task != null) await task;
      return;
    }

    final session = _SftpSession(
      connectionId: connectionId,
      connectionName: config.name,
      currentPath: _lastPaths[connectionId] ?? '.',
      targetBinding: runtimeTarget.binding,
    );
    _sessions[connectionId] = session;
    _activeConnectionId = connectionId;
    session.state = SftpConnectionState.connecting;
    session.errorMessage = null;
    notifyListeners();
    final task = _connect(
      session,
      runtimeTarget,
      onUnknownHostKey: onUnknownHostKey,
    );
    _connectTasks[connectionId] = task;
    try {
      await task;
    } finally {
      if (identical(_connectTasks[connectionId], task)) {
        _connectTasks.remove(connectionId);
      }
    }
  }

  Future<void> _connect(
    _SftpSession session,
    ConnectionRuntimeTarget target, {
    dynamic onUnknownHostKey,
  }) async {
    final config = target.config;
    final credentials = SshCredentials(
      password: target.password,
      privateKey: target.privateKey,
    );
    try {
      final client = await _clientFactory.connectClient(
        config,
        credentials: credentials,
        onUnknownHostKey: onUnknownHostKey,
        peerId: _peerIdResolver?.call(config),
      );
      if (!session.isCurrent(_sessions)) {
        client.close();
        return;
      }
      session.client = client;
      final sftp = await client.sftp().timeout(const Duration(seconds: 15));
      if (!session.isCurrent(_sessions)) {
        sftp.close();
        client.close();
        return;
      }
      session.sftp = sftp;
      session.state = SftpConnectionState.connected;
      AppLogService.instance.info(
        'SFTP connected',
        details: SftpLogSafety.details(
          operation: 'connect',
          connectionId: session.connectionId,
        ),
      );
      notify();
      await _openLastKnownPath(session);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP connect failed',
        details: SftpLogSafety.details(
          operation: 'connect',
          connectionId: session.connectionId,
          error: e,
        ),
      );
      session.close();
      session.client = null;
      session.sftp = null;
      session.state = SftpConnectionState.error;
      session.errorMessage = 'SFTP connection failed: $e';
      notify();
    }
  }
}
