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
    // 仅在 span 已开始（traceId 存在）时上报失败，避免为早期预检失败产生
    // 无 started 对称事件的孤立 failed 记录。
    if (_telemetryTraceIds.containsKey(sessionId)) {
      _failSessionTelemetry(
        session,
        'connect',
        errorCode: _mapMessageErrorCode(message),
        errorMessage: message,
      );
    }
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

  // ---------------------------------------------------------------------------
  // 业务遥测：SSH 会话生命周期 span。
  //
  // 同一个 SSH 会话的 started -> connected -> terminated/failed 全部共享一个
  // traceId（TelemetryClient 未传入 traceId 时自动生成），用于端到端关联。
  // 事件属性严格限制在 contract 白名单内（app_core 不允许编辑，详见任务映射）。
  // ---------------------------------------------------------------------------

  /// 开始一个 SSH 会话 span，生成 traceId 并上报 started 事件。
  void _startSessionTelemetry(SshSession session, ConnectionConfig config) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTraceIds[session.id] ??= newTelemetryTraceId();
    _telemetrySpanStartedAt[session.id] = DateTime.now();
    unawaited(
      client.record(
        event: TelemetryEvents.sshSessionStarted,
        sessionId: session.id,
        traceId: traceId,
        properties: {
          'auth_method': config.authMethod.name,
          'session_type': 'terminal',
        },
      ),
    );
  }

  /// 结束 SSH 会话 span（正常断开），上报 terminated 事件。
  void _terminateSessionTelemetry(SshSession session, {int exitCode = 0}) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTraceIds.remove(session.id);
    final startedAt = _telemetrySpanStartedAt.remove(session.id);
    unawaited(
      client.record(
        event: TelemetryEvents.sshSessionTerminated,
        sessionId: session.id,
        traceId: traceId,
        properties: {
          'duration_ms': _telemetryElapsedMs(startedAt),
          'exit_code': exitCode,
        },
      ),
    );
  }

  /// 会话建立成功后记录连接成功事件。
  void _recordSessionConnectedTelemetry(SshSession session) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTraceIds[session.id];
    if (traceId == null) return;
    unawaited(
      client.record(
        event: TelemetryEvents.sshSessionConnected,
        sessionId: session.id,
        traceId: traceId,
        properties: {'session_type': 'terminal'},
      ),
    );
  }

  /// 以失败状态结束 SSH 会话 span，上报 failed 事件并附带注册的错误码。
  void _failSessionTelemetry(
    SshSession session,
    String stage, {
    TelemetryErrorCodeDefinition? errorCode,
    String? errorMessage,
    int retryCount = 0,
  }) {
    final client = telemetryClient;
    if (client == null) return;
    final traceId = _telemetryTraceIds.remove(session.id);
    _telemetrySpanStartedAt.remove(session.id);
    unawaited(
      client.record(
        event: TelemetryEvents.sshSessionFailed,
        sessionId: session.id,
        traceId: traceId,
        errorCode: errorCode,
        errorMessage: errorMessage,
        properties: {'stage': stage, 'retry_count': retryCount},
      ),
    );
  }

  static int _telemetryElapsedMs(DateTime? startedAt) =>
      telemetryElapsedMs(startedAt);

  /// 后台桥接错误消息映射到已注册 SSH 错误码（无法访问异常对象）。
  TelemetryErrorCodeDefinition _mapBackgroundErrorCode(String? error) {
    final message = error?.toLowerCase() ?? '';
    if (message.contains('auth') || message.contains('password')) {
      return TelemetryErrorCodes.sshAuthFailed;
    }
    if (message.contains('host key') || message.contains('fingerprint')) {
      return TelemetryErrorCodes.sshHostKeyMismatch;
    }
    if (message.contains('timeout')) {
      return TelemetryErrorCodes.sshTimeout;
    }
    return TelemetryErrorCodes.sshConnectFailed;
  }

  /// 根据错误消息字符串映射到已注册 SSH 错误码。
  TelemetryErrorCodeDefinition _mapMessageErrorCode(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('auth') ||
        lower.contains('password') ||
        lower.contains('credential')) {
      return TelemetryErrorCodes.sshAuthFailed;
    }
    if (lower.contains('host key') ||
        lower.contains('fingerprint') ||
        lower.contains('known_hosts')) {
      return TelemetryErrorCodes.sshHostKeyMismatch;
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return TelemetryErrorCodes.sshTimeout;
    }
    return TelemetryErrorCodes.sshConnectFailed;
  }

  /// 将连接异常映射到 contract 已注册的 SSH 错误码。
  TelemetryErrorCodeDefinition _mapSshErrorCode(
    Object error,
    ConnectionConfig config,
  ) {
    final message = error.toString().toLowerCase();
    if (message.contains('authentication') ||
        message.contains('authenticate') ||
        message.contains('password') ||
        message.contains('passphrase') ||
        message.contains('key')) {
      return TelemetryErrorCodes.sshAuthFailed;
    }
    if (message.contains('timeout') || message.contains('timed out')) {
      return TelemetryErrorCodes.sshTimeout;
    }
    if (message.contains('host key') ||
        message.contains('fingerprint') ||
        message.contains('HostKey')) {
      return TelemetryErrorCodes.sshHostKeyMismatch;
    }
    return TelemetryErrorCodes.sshConnectFailed;
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
