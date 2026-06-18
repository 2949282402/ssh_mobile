import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../features/connection/models/connection.dart';
import 'app_log_service.dart';
import 'background_service.dart';
import '../core/services/ssh_client_factory.dart';
import '../core/services/ssh_host_key_policy.dart';
import 'storage_service.dart';
import 'terminal_history_service.dart';

part 'ssh/ssh_session.dart';
part 'ssh/local_ssh_runtime.dart';

/// SSH 会话管理器。每个连接最多可以有多个 SshSession（窗口）。
///
/// 双模架构：
/// 1. 桌面端（Windows/macOS）：直接本地 SSH 连接（_LocalSshRuntime）
/// 2. 移动端（Android/iOS）：通过 flutter_background_service 桥接（MethodChannel）
///
/// tmux 集成：连接后自动创建或 attach 到指定 tmux session，服务端持久化。
/// App 重启后通过 RestorableTmuxSession 列表自动恢复会话。
class SshService extends ChangeNotifier implements SshClientAdapter {
  final StorageService _storageService;
  late final SshClientFactory _clientFactory =
      SshClientFactory(_storageService);
  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();
  final TerminalHistoryService _historyService = TerminalHistoryService();

  final Map<String, SshSession> _sessions = {};
  final Map<String, _LocalSshRuntime> _localRuntimes = {};
  final Map<String, Completer<void>> _connectCompleters = {};
  final Set<String> _closingSessionIds = {};
  final Random _random = Random();
  List<SshSession> _sessionsView = const [];
  SshServerOverviewSnapshot _serverOverviewSnapshot =
      const SshServerOverviewSnapshot.empty();
  StreamSubscription<Map<String, dynamic>?>? _stateSub;
  StreamSubscription<Map<String, dynamic>?>? _outputSub;
  StreamSubscription<Map<String, dynamic>?>? _keepAliveSub;
  StreamSubscription<Map<String, dynamic>?>? _appLogSub;
  String? _lastSessionId;
  String? _lastErrorMessage;
  bool _restoredTmuxSessions = false;

  SshService(this._storageService) {
    if (_usesBackgroundService) {
      _listenToBackgroundService();
    } else {
      AppLogService.instance.info(
        'Background SSH service disabled on this platform',
      );
    }
    unawaited(restoreTmuxSessions());
  }

  bool get _usesBackgroundService {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
  }

  @override
  List<SshSession> get sessions => _sessionsView;
  @override
  SshServerOverviewSnapshot get serverOverviewSnapshot =>
      _serverOverviewSnapshot;
  @override
  bool get isConnected =>
      _sessions.values.any((session) => session.isConnected);
  @override
  SshConnectionState get state =>
      currentSession?.state ??
      (isConnected
          ? SshConnectionState.connected
          : SshConnectionState.disconnected);
  @override
  String? get errorMessage => currentSession?.errorMessage ?? _lastErrorMessage;
  @override
  SshSession? get currentSession => _lastSessionId == null
      ? null
      : _sessions[_lastSessionId] ?? _sessions.values.lastOrNull;
  @override
  String? get activeConnectionId => currentSession?.connectionId;

  @override
  SshSession? getSession(String sessionId) => _sessions[sessionId];

  @override
  Future<String> loadSessionHistoryText(String sessionId) {
    return _historyService.readTail(sessionId);
  }

  @override
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() {
    return _storageService.loadTerminalHistoryRecords();
  }

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) {
    return _storageService.removeTerminalHistoryRecord(sessionId);
  }

  @override
  bool hasConnectedSession(String connectionId) {
    return _serverOverviewSnapshot.forConnection(connectionId).hasConnected;
  }

  @override
  SshSession? latestSessionForConnection(String connectionId) {
    for (final session in _sessions.values.toList().reversed) {
      if (session.connectionId == connectionId) return session;
    }
    return null;
  }

  @override
  int sessionCountForConnection(String connectionId) {
    return _serverOverviewSnapshot.forConnection(connectionId).count;
  }

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    final sessionIds = _sessions.values
        .where((session) => session.connectionId == connectionId)
        .map((session) => session.id)
        .toList();

    for (final sessionId in sessionIds) {
      await disconnectSession(sessionId);
    }
  }

  @override
  bool renameSession(String sessionId, String name) {
    final session = _sessions[sessionId];
    final nextName = name.trim();
    if (session == null || nextName.isEmpty) return false;
    if (_isSessionNameTaken(nextName, exceptSessionId: sessionId)) {
      return false;
    }
    session.displayName = nextName;
    unawaited(_saveRestorableTmuxSession(session));
    _notifySessionMetadataChanged();
    return true;
  }

  @override
  void setSessionFontSize(String sessionId, double fontSize) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.fontSize = fontSize.clamp(
        SshSession.minTerminalFontSize, SshSession.maxTerminalFontSize);
    unawaited(_saveRestorableTmuxSession(session));
    _notifySessionMetadataChanged();
  }

  @override
  Future<void> restoreTmuxSessions() async {
    if (_restoredTmuxSessions) return;
    _restoredTmuxSessions = true;
    await _storageService.initFuture;
    final storedSessions = await _storageService.loadRestorableTmuxSessions();
    AppLogService.instance.info(
      'Restoring tmux sessions',
      details: 'count=${storedSessions.length}',
    );
    if (storedSessions.isEmpty) return;

    for (final stored in storedSessions) {
      final config = _storageService.getConnection(stored.connectionId);
      if (config?.launchMode != TerminalLaunchMode.tmux) {
        AppLogService.instance.warning(
          'Removing stale restorable tmux session',
          details: 'sessionId=${stored.sessionId}',
        );
        await _storageService.removeRestorableTmuxSession(stored.sessionId);
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
    notifyListeners();

    for (final session in _sessions.values.toList()) {
      final config = _storageService.getConnection(session.connectionId);
      if (config?.launchMode != TerminalLaunchMode.tmux ||
          session.isConnected) {
        continue;
      }
      unawaited(connect(session.connectionId, sessionId: session.id));
    }
  }

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
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

  @override
  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async {
    final existing = _sessions[sessionId];
    if (existing?.isConnected == true) {
      _lastSessionId = sessionId;
      return true;
    }

    await connect(connectionId, sessionId: sessionId);
    return _sessions[sessionId]?.isConnected == true;
  }

  @override
  Future<bool> ensureConnected(String connectionId) async {
    final existing = latestSessionForConnection(connectionId);
    if (existing?.isConnected == true) {
      _lastSessionId = existing!.id;
      return true;
    }

    final sessionId = await openSession(connectionId);
    return sessionId != null;
  }

  @override
  Future<void> connect(
    String connectionId, {
    String? sessionId,
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      AppLogService.instance.error(
        'Connection config not found',
        details: 'connectionId=$connectionId sessionId=$sessionId',
      );
      _setSessionError(
        sessionId ?? _createSessionId(connectionId),
        connectionId,
        'Unknown',
        'Connection config not found',
      );
      return;
    }

    final id = sessionId ?? _createSessionId(connectionId);
    final requestedDisplayName = displayName?.trim();
    if (requestedDisplayName?.isNotEmpty == true &&
        _isSessionNameTaken(requestedDisplayName!, exceptSessionId: id)) {
      AppLogService.instance.warning(
        'Window name already exists',
        details: 'name=$requestedDisplayName sessionId=$id',
      );
      _setSessionError(
        id,
        connectionId,
        config.name,
        'Window name already exists',
      );
      return;
    }
    final defaultDisplayName = requestedDisplayName?.isNotEmpty == true
        ? requestedDisplayName!
        : _defaultDisplayName(config.host, connectionId);
    final session = _sessions.putIfAbsent(
      id,
      () => SshSession(
        id: id,
        connectionId: connectionId,
        connectionName: config.name,
        displayName: defaultDisplayName,
        outputController: StreamController<String>.broadcast(),
      ),
    );
    _refreshSessionsView();

    if (session.state == SshConnectionState.connecting &&
        _connectCompleters.containsKey(id)) {
      await _connectCompleters[id]!.future;
      return;
    }

    session.state = SshConnectionState.connecting;
    session.errorMessage = null;
    session.tmuxAutoDeleteSeconds = config.tmuxAutoDeleteSeconds;
    session.updatedAt = DateTime.now();
    _lastErrorMessage = null;
    _lastSessionId = id;
    final launchMode = _effectiveLaunchMode(config);
    final connectCompleter = Completer<void>();
    _connectCompleters[id] = connectCompleter;
    unawaited(_saveTerminalHistoryRecord(session));
    AppLogService.instance.info(
      'Session connecting',
      details: 'sessionId=$id connection=${config.name} '
          'mode=${launchMode.name} platform=${config.serverPlatform.name}',
    );
    _notifySessionMetadataChanged();

    try {
      // Allow UI to render the connecting state and connection dialog entrance
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final credentials = await _clientFactory.loadCredentials(config);

      if (launchMode == TerminalLaunchMode.tmux) {
        session.tmuxSessionName ??= _uniqueTmuxSessionName(
          _tmuxSessionNameForSession(session),
          exceptSessionId: id,
        );
      } else {
        session.tmuxSessionName = null;
      }
      if (session.tmuxSessionName != null) {
        AppLogService.instance.info(
          'Using tmux session',
          details: 'sessionId=$id tmux=${session.tmuxSessionName}',
        );
      }
      if (_usesBackgroundService) {
        if (config.hostKeyFingerprint?.isNotEmpty != true) {
          await _verifyHostKeyBeforeBackground(
            config: config,
            credentials: credentials,
            onUnknownHostKey: onUnknownHostKey,
          );
        }
        await BackgroundServiceManager.start(
          connectionName: _notificationSummary(),
        );
        // Let the UI render while foreground service is starting up
        await Future<void>.delayed(const Duration(milliseconds: 16));
        _backgroundService.invoke('sshConnect', {
          'sessionId': id,
          'id': config.id,
          'name': config.name,
          'host': config.host,
          'port': config.port,
          'username': config.username,
          'password': credentials.password,
          'privateKey': credentials.privateKey,
          'authMethod': config.authMethod.name,
          'hostKeyFingerprint': config.hostKeyFingerprint,
          'hostKeyAlgorithm': config.hostKeyAlgorithm,
          'hostKeyTrustedAt': config.hostKeyTrustedAt?.toIso8601String(),
          'terminalWidth': config.terminalWidth,
          'terminalHeight': config.terminalHeight,
          'keepAliveInterval': 3,
          'launchMode': launchMode.name,
          'tmuxSessionName': session.tmuxSessionName,
          'tmuxAutoDeleteSeconds': config.tmuxAutoDeleteSeconds,
        });
      } else {
        // Allow UI rendering before initiating local cryptographic handshake
        await Future<void>.delayed(const Duration(milliseconds: 16));
        await _connectLocalSession(
          session: session,
          config: config,
          credentials: credentials,
          launchMode: launchMode,
          onUnknownHostKey: onUnknownHostKey,
        );
      }

      await connectCompleter.future.timeout(
        const Duration(seconds: 30),
      );
    } on TimeoutException {
      AppLogService.instance.error(
        'Session connect timed out',
        details: 'sessionId=$id connection=${config.name}',
      );
      _setSessionError(id, connectionId, config.name, 'Connection timed out');
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Session connect failed',
        error: e,
        stackTrace: stackTrace,
        details: 'sessionId=$id connection=${config.name}',
      );
      _setSessionError(id, connectionId, config.name, 'Connection failed: $e');
    }
  }

  @override
  Future<void> disconnectSession(String sessionId) async {
    AppLogService.instance
        .info('Disconnecting session', details: 'sessionId=$sessionId');
    _closingSessionIds.add(sessionId);
    if (_usesBackgroundService) {
      _backgroundService.invoke('sshDisconnect', {'sessionId': sessionId});
    } else {
      await _closeLocalSession(sessionId, destroyTmux: true);
    }
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.state = SshConnectionState.disconnected;
      session.errorMessage = 'Closed by user';
      session.updatedAt = DateTime.now();
      unawaited(_saveTerminalHistoryRecord(session));
    }
    await session?.close();
    await _storageService.removeRestorableTmuxSession(sessionId);
    _connectCompleters.remove(sessionId);
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
      unawaited(_saveTerminalHistoryRecord(session));
    }
    await session?.close();
    await _storageService.removeRestorableTmuxSession(sessionId);
    _connectCompleters.remove(sessionId);
    if (_lastSessionId == sessionId) {
      _lastSessionId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
    await _stopServiceIfIdle();
    _refreshSessionsView();
    _notifySessionMetadataChanged();
  }

  @override
  Future<void> disconnect() async {
    AppLogService.instance.info(
      'Disconnecting all sessions',
      details: 'count=${_sessions.length}',
    );
    _closingSessionIds.addAll(_sessions.keys);
    if (_usesBackgroundService) {
      _backgroundService.invoke('sshDisconnectAll');
    } else {
      for (final sessionId in _sessions.keys.toList()) {
        await _closeLocalSession(sessionId, destroyTmux: true);
      }
    }
    for (final session in _sessions.values) {
      session.state = SshConnectionState.disconnected;
      session.errorMessage = 'Closed by user';
      session.updatedAt = DateTime.now();
      unawaited(_saveTerminalHistoryRecord(session));
      await session.close();
    }
    _sessions.clear();
    _refreshSessionsView();
    _connectCompleters.clear();
    _lastSessionId = null;
    await _storageService.clearRestorableTmuxSessions();
    await BackgroundServiceManager.stop();
    notifyListeners();
  }

  @override
  void resizeTerminal(String sessionId, int width, int height) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      if (_usesBackgroundService) {
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

  @override
  void sendData(String sessionId, String data) {
    final session = _sessions[sessionId];
    if (session?.isConnected == true) {
      if (_usesBackgroundService) {
        _backgroundService.invoke('sshInput', {
          'sessionId': sessionId,
          'data': data,
        });
      } else {
        _localRuntimes[sessionId]?.shell.stdin.add(utf8.encode(data));
      }
    }
  }

  @override
  void sendBytes(String sessionId, Uint8List data) {
    sendData(sessionId, String.fromCharCodes(data));
  }

  /// 执行单次 SSH 命令并返回结果。
  /// AI 工具和诊断场景使用此方法，通过普通 SSH exec 执行（非 tmux）。
  /// 不复用交互式终端会话，每条命令独立连接，用完即关。
  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final config = _storageService.getConnection(connectionId);
    if (config == null) {
      throw StateError('Connection config not found');
    }
    // AI tools and diagnostics must use plain SSH exec. Do not attach tmux or
    // reuse terminal sessions here; tmux is only for interactive terminal UI.
    final client = await _clientFactory.connectClient(
      config,
      onUnknownHostKey: onUnknownHostKey,
    );
    try {
      final result = await client.runWithResult(command).timeout(timeout);
      return RemoteCommandResult(
        exitCode: result.exitCode,
        stdout: utf8.decode(result.stdout, allowMalformed: true),
        stderr: utf8.decode(result.stderr, allowMalformed: true),
      );
    } finally {
      client.close();
    }
  }

  /// Mobile background isolates cannot ask the user to trust an unknown host
  /// key, so the UI isolate performs the first TOFU check before handoff.
  Future<void> _verifyHostKeyBeforeBackground({
    required ConnectionConfig config,
    required SshCredentials credentials,
    required SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final client = await _clientFactory.connectClient(
      config,
      credentials: credentials,
      timeout: const Duration(seconds: 12),
      onUnknownHostKey: onUnknownHostKey,
    );
    try {
      await client.ping().timeout(const Duration(seconds: 8));
    } finally {
      client.close();
    }
  }

  /// 本地（桌面端）SSH 连接逻辑。建立 SSH client → 创建 Shell（xterm-256color）→
  /// 如果使用 tmux 模式则发送 attach 命令 -> 启动 keep-alive 心跳。
  ///
  /// 三种监听流：stdout（数据输出）、stderr（错误输出）、keepAlive（保活探测）
  Future<void> _connectLocalSession({
    required SshSession session,
    required ConnectionConfig config,
    required SshCredentials credentials,
    required TerminalLaunchMode launchMode,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    await _closeLocalSession(session.id, destroyTmux: false);
    AppLogService.instance.info(
      'Connecting SSH locally',
      details: 'sessionId=${session.id} host=${config.host}',
    );

    final client = await _clientFactory.connectClient(
      config,
      credentials: credentials,
      onUnknownHostKey: onUnknownHostKey,
    );
    final isTmux = launchMode == TerminalLaunchMode.tmux;
    final termType = config.serverPlatform == ServerPlatform.windows
        ? 'ms-terminal'
        : 'xterm-256color';

    SSHSession shell;
    if (isTmux) {
      final sessionName = session.tmuxSessionName!;
      shell = await client.shell(
        pty: SSHPtyConfig(
          width: config.terminalWidth,
          height: config.terminalHeight,
          type: termType,
        ),
      );

      final escapedName = sessionName.replaceAll("'", "'\"'\"'");
      final attachCmd = 'exec tmux new-session -A -s \'$escapedName\'\r';
      shell.write(utf8.encode(attachCmd));
    } else {
      shell = await client.shell(
        pty: SSHPtyConfig(
          width: config.terminalWidth,
          height: config.terminalHeight,
          type: termType,
        ),
      );
    }

    final runtime = _LocalSshRuntime(
      sessionId: session.id,
      client: client,
      shell: shell,
      tmuxSessionName: session.tmuxSessionName,
    );

    _localRuntimes[session.id] = runtime;

    runtime.stdoutSub = shell.stdout.listen((data) {
      final text = utf8.decode(data, allowMalformed: true);
      _onLocalSessionData(session.id, text);
    });

    runtime.stderrSub = shell.stderr.listen((data) {
      final text = utf8.decode(data, allowMalformed: true);
      _onLocalSessionErrorData(session.id, text);
    });

    unawaited(shell.done.then((_) {
      _onLocalSessionDone(session.id);
    }));

    _startLocalKeepAlive(runtime);

    session.state = SshConnectionState.connected;
    session.errorMessage = null;
    session.updatedAt = DateTime.now();

    final completer = _connectCompleters.remove(session.id);
    completer?.complete();

    unawaited(_saveRestorableTmuxSession(session));
    _notifySessionMetadataChanged();
  }

  void _onLocalSessionData(String sessionId, String text) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.addOutput(text);
    unawaited(_historyService.append(sessionId, text));
  }

  void _onLocalSessionErrorData(String sessionId, String text) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.addOutput(text);
    unawaited(_historyService.append(sessionId, text));
  }

  void _onLocalSessionDone(String sessionId) {
    final runtime = _localRuntimes[sessionId];
    if (runtime == null) return;
    if (_closingSessionIds.contains(sessionId)) {
      _closingSessionIds.remove(sessionId);
      return;
    }
    AppLogService.instance.warning(
      'Local SSH session closed unexpectedly',
      details: 'sessionId=$sessionId',
    );
    unawaited(_reconnectLocalSession(sessionId));
  }

  Future<void> _reconnectLocalSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.state = SshConnectionState.connecting;
    _notifySessionMetadataChanged();

    for (var i = 1; i <= 5; i++) {
      if (!_sessions.containsKey(sessionId) ||
          _closingSessionIds.contains(sessionId)) {
        return;
      }
      try {
        AppLogService.instance.info(
          'Reconnecting local SSH session',
          details: 'sessionId=$sessionId attempt=$i',
        );
        final config = _storageService.getConnection(session.connectionId);
        if (config == null) return;
        final credentials = await _clientFactory.loadCredentials(config);
        final launchMode = _effectiveLaunchMode(config);
        await _connectLocalSession(
          session: session,
          config: config,
          credentials: credentials,
          launchMode: launchMode,
        );
        return;
      } catch (e) {
        AppLogService.instance.error(
          'Reconnect attempt failed',
          error: e,
          details: 'sessionId=$sessionId attempt=$i',
        );
        final delay = min(30, pow(2, i).toInt());
        await Future<void>.delayed(Duration(seconds: delay));
      }
    }

    if (_sessions.containsKey(sessionId)) {
      session.state = SshConnectionState.error;
      session.errorMessage = 'Reconnect failed after 5 attempts';
      _notifySessionMetadataChanged();
    }
  }

  void _startLocalKeepAlive(_LocalSshRuntime runtime) {
    runtime.keepAliveTimer =
        Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (runtime.pingInFlight) {
        runtime.keepAliveFailures++;
        AppLogService.instance.warning(
          'Keep-alive timeout',
          details:
              'sessionId=${runtime.sessionId} failures=${runtime.keepAliveFailures}',
        );
        if (runtime.keepAliveFailures >= 3) {
          timer.cancel();
          _onLocalSessionDone(runtime.sessionId);
        }
        return;
      }

      runtime.pingInFlight = true;
      try {
        await runtime.client.ping();
        runtime.pingInFlight = false;
        runtime.keepAliveFailures = 0;
      } catch (e) {
        runtime.pingInFlight = false;
        runtime.keepAliveFailures++;
        AppLogService.instance.error(
          'Keep-alive ping failed',
          error: e,
          details:
              'sessionId=${runtime.sessionId} failures=${runtime.keepAliveFailures}',
        );
        if (runtime.keepAliveFailures >= 3) {
          timer.cancel();
          _onLocalSessionDone(runtime.sessionId);
        }
      }
    });
  }

  Future<void> _closeLocalSession(String sessionId,
      {required bool destroyTmux}) async {
    final runtime = _localRuntimes.remove(sessionId);
    if (runtime == null) return;

    if (destroyTmux && runtime.tmuxSessionName != null) {
      try {
        final session = _sessions[sessionId];
        final killCmd = session?.tmuxKillCommand;
        if (killCmd != null) {
          AppLogService.instance.info(
            'Killing tmux session on disconnect',
            details: 'sessionId=$sessionId tmux=${runtime.tmuxSessionName}',
          );
          final client = runtime.client;
          await client.run(killCmd).timeout(const Duration(seconds: 3));
        }
      } catch (e) {
        AppLogService.instance.error(
          'Failed to kill remote tmux session',
          error: e,
          details: 'sessionId=$sessionId',
        );
      }
    }

    runtime.close();
  }

  void _listenToBackgroundService() {
    _backgroundService.on('sshStateChanged').listen((data) {
      if (data == null) return;
      final String sessionId = data['sessionId'];
      final String stateName = data['state'];
      final String? error = data['errorMessage'];

      final state = SshConnectionState.values.firstWhere(
        (e) => e.name == stateName,
        orElse: () => SshConnectionState.disconnected,
      );

      final session = _sessions[sessionId];
      if (session != null) {
        session.state = state;
        session.errorMessage = error;
        session.updatedAt = DateTime.now();

        if (state == SshConnectionState.connected) {
          final completer = _connectCompleters.remove(sessionId);
          completer?.complete();
        } else if (state == SshConnectionState.error) {
          final completer = _connectCompleters.remove(sessionId);
          completer?.completeError(StateError(error ?? 'Connection failed'));
        }

        unawaited(_saveTerminalHistoryRecord(session));
        _notifySessionMetadataChanged();
      }
    });

    _backgroundService.on('sshDataReceived').listen((data) {
      if (data == null) return;
      final String sessionId = data['sessionId'];
      final String text = data['data'];

      final session = _sessions[sessionId];
      if (session != null) {
        session.addOutput(text);
        unawaited(_historyService.append(sessionId, text));
      }
    });

    _backgroundService.on('sshOverviewUpdated').listen((data) {
      if (data == null) return;
      final overviewMap = data['overview'] as Map;
      final windowCount = data['windowCount'] as int;

      final byConnection = <String, SshConnectionOverview>{};
      for (final entry in overviewMap.entries) {
        final val = entry.value as Map;
        final latestStateName = val['latestState'] as String?;
        final state = latestStateName == null
            ? null
            : SshConnectionState.values.firstWhere(
                (e) => e.name == latestStateName,
                orElse: () => SshConnectionState.disconnected,
              );

        byConnection[entry.key as String] = SshConnectionOverview(
          count: val['count'] as int,
          latestState: state,
          hasConnected: val['hasConnected'] as bool,
        );
      }

      _serverOverviewSnapshot = SshServerOverviewSnapshot(
        byConnection: byConnection,
        windowCount: windowCount,
      );
      notifyListeners();
    });

    _backgroundService.on('sshLogReceived').listen((data) {
      if (data == null) return;
      final String message = data['message'];
      final String? errorText = data['error'];
      final String levelName = data['level'] ?? 'info';

      if (levelName == 'error') {
        AppLogService.instance.error('[Background] $message', error: errorText);
      } else if (levelName == 'warning') {
        AppLogService.instance.warning('[Background] $message');
      } else {
        AppLogService.instance.info('[Background] $message');
      }
    });
  }

  void _refreshSessionsView() {
    _sessionsView = List.unmodifiable(_sessions.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));
  }

  void _notifySessionMetadataChanged() {
    _refreshSessionsView();
    notifyListeners();
  }

  String _createSessionId(String connectionId) {
    return '$connectionId-${DateTime.now().millisecondsSinceEpoch}-${_random.nextInt(10000)}';
  }

  String _defaultDisplayName(String host, String connectionId) {
    final count = sessionCountForConnection(connectionId);
    return count == 0 ? host : '$host (${count + 1})';
  }

  String defaultDisplayNameForConnection(String connectionId) {
    final config = _storageService.getConnection(connectionId);
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

  String _uniqueTmuxSessionName(String baseName,
      {required String exceptSessionId}) {
    bool exists(String name) {
      return _sessions.values.any((session) =>
          session.id != exceptSessionId &&
          session.tmuxSessionName != null &&
          session.tmuxSessionName!.toLowerCase() == name.toLowerCase());
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
    await _storageService.saveRestorableTmuxSession(
      RestorableTmuxSession(
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
    await _storageService.saveTerminalHistoryRecord(
      TerminalHistoryRecord(
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
    if (active.length == 1) return 'Connected to ${active.first.displayName}';
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

  @override
  void dispose() {
    _stateSub?.cancel();
    _outputSub?.cancel();
    _keepAliveSub?.cancel();
    _appLogSub?.cancel();
    unawaited(_historyService.flush());
    for (final runtime in _localRuntimes.values) {
      runtime.close();
    }
    for (final session in _sessions.values) {
      session.close();
    }
    super.dispose();
  }
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
