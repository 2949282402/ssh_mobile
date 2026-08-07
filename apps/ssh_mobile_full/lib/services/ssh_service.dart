import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../features/connection/models/connection.dart';
import 'app_log_service.dart';
import 'app_settings.dart';
import 'background_service.dart';
import '../core/services/ssh_client_factory.dart';
import '../core/services/ssh_host_key_policy.dart';
import 'connection_target_binding.dart';
import 'remote_target_scope.dart';
import 'remote_command_decoder.dart';
import 'storage_service.dart';
import 'terminal_history_service.dart';
import '../utils/startup_instrumentation.dart';

part 'ssh/ssh_session.dart';
part 'ssh/local_ssh_runtime.dart';
part 'ssh/ssh_connection_runtime.dart';
part 'ssh/ssh_session_metadata.dart';

/// SSH 会话管理器。每个连接最多可以有多个 SshSession（窗口）。
///
/// 双模架构：
/// 1. 桌面端（Windows/macOS）：直接本地 SSH 连接（_LocalSshRuntime）
/// 2. 移动端（Android/iOS）：通过 flutter_background_service 桥接（MethodChannel）
///
/// tmux 集成：连接后自动创建或 attach 到指定 tmux session，服务端持久化。
/// App 重启后通过 RestorableTmuxSession 列表自动恢复会话。
class SshService extends ChangeNotifier
    implements SshClientAdapter, ssh_core.SshSessionManager {
  final StorageService _storageService;
  final AppSettings? _appSettings;
  late final SshClientFactory _clientFactory = SshClientFactory(
    _storageService,
  );
  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();
  final TerminalHistoryService _historyService = TerminalHistoryService();

  final Map<String, SshSession> _sessions = {};
  final Map<String, ConnectionTargetBinding> _sessionTargetBindings = {};
  final Map<String, _LocalSshRuntime> _localRuntimes = {};
  final Map<String, Completer<void>> _connectCompleters = {};
  final Set<String> _closingSessionIds = {};
  // Step08 的共享 Pool 先挂在现有兼容 Service 上，确保 App Scope 只有一个
  // SSH Owner；Terminal Pilot 会逐步把旧方法面迁到 package Manager。
  final ssh_core.SshSessionPool _coreSessionPool = ssh_core.SshSessionPool();
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
  bool _initialized = false;
  Future<void>? _initFuture;
  Future<void>? _managerCloseFuture;

  SshService(this._storageService, {this._appSettings}) {
    StartupInstrumentation.instance.recordServiceConstructed('SshService');
  }

  @override
  bool get initialized => _initialized;

  @override
  Future<void> ensureInitialized() {
    if (_initialized) return Future.value();
    if (_initFuture != null) return _initFuture!;

    _initFuture = _doInit();
    return _initFuture!;
  }

  @override
  Future<ssh_core.SshSessionLease> acquire({
    required String sessionId,
    required Future<ssh_core.SshSession> Function() create,
  }) {
    return _coreSessionPool.acquire(sessionId: sessionId, create: create);
  }

  /// 关闭 App Scope SSH Manager；旧 ChangeNotifier API 由同一实例兼容承载。
  @override
  Future<void> close() {
    final existing = _managerCloseFuture;
    if (existing != null) return existing;
    final future = _closeManager();
    _managerCloseFuture = future;
    return future;
  }

  Future<void> _closeManager() async {
    try {
      await ensureInitialized();
    } finally {
      await _coreSessionPool.close();
      dispose();
    }
  }

  Future<void> _doInit() async {
    try {
      StartupInstrumentation.instance.recordServiceInitialized('SshService');
      if (_usesBackgroundService) {
        _listenToBackgroundService();
      } else {
        AppLogService.instance.info(
          'Background SSH service disabled on this platform',
        );
      }
      await restoreTmuxSessions();
      _initialized = true;
    } catch (e) {
      _initFuture = null;
      rethrow;
    }
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
      SshSession.minTerminalFontSize,
      SshSession.maxTerminalFontSize,
    );
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

  @override
  Future<bool> ensureSessionConnected(
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
    final id = sessionId ?? _createSessionId(connectionId);
    ConnectionRuntimeTarget runtimeTarget;
    try {
      await Future<void>.delayed(Duration.zero);
      runtimeTarget = await RemoteTargetScope.resolveIfBound(
        _storageService,
        connectionId,
      );
    } on RemoteTargetScopeException catch (e) {
      AppLogService.instance.error(
        'SSH connection target unavailable',
        error: e,
        details: 'connectionId=$connectionId sessionId=$id code=${e.code}',
      );
      _setSessionError(id, connectionId, 'Unknown', e.message);
      return;
    }
    final config = runtimeTarget.config;
    final credentials = SshCredentials(
      password: runtimeTarget.password,
      privateKey: runtimeTarget.privateKey,
    );

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

    if (kIsWeb) {
      _setSessionError(
        id,
        connectionId,
        config.name,
        'Web 浏览器由于沙盒安全限制，不支持直接建立原始 TCP 连接。如果您需要使用 SSH 功能，请下载并使用 Android 客户端或桌面端（Windows/macOS/Linux）应用。\n\nWeb browsers do not support direct TCP connections due to sandbox constraints. To use SSH, please download and run the Android or Desktop client.',
      );
      return;
    }

    if (session.state == SshConnectionState.connecting &&
        _connectCompleters.containsKey(id)) {
      await _connectCompleters[id]!.future;
      return;
    }

    _sessionTargetBindings[id] = runtimeTarget.binding;
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
      details:
          'sessionId=$id connection=${config.name} '
          'mode=${launchMode.name} platform=${config.serverPlatform.name}',
    );
    _notifySessionMetadataChanged();

    try {
      // Allow UI to render the connecting state and connection dialog entrance
      await Future<void>.delayed(const Duration(milliseconds: 16));

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
          showConnectionName:
              _appSettings?.showServerNamesInNotifications ?? false,
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
          'showServerNameInNotification':
              _appSettings?.showServerNamesInNotifications ?? false,
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

      await connectCompleter.future.timeout(const Duration(seconds: 30));
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
    AppLogService.instance.info(
      'Disconnecting session',
      details: 'sessionId=$sessionId',
    );
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
    _sessionTargetBindings.remove(sessionId);
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
    _sessionTargetBindings.remove(sessionId);
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
    _sessionTargetBindings.clear();
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
    final target = await RemoteTargetScope.resolveIfBound(
      _storageService,
      connectionId,
    );
    return _runOneShotCommandForTarget(
      target: target,
      command: command,
      timeout: timeout,
      onUnknownHostKey: onUnknownHostKey,
    );
  }

  /// Executes against an explicitly approved target binding.
  ///
  /// Long-running Playbooks should call this for every step so a connection
  /// edit between steps stops execution instead of silently changing servers.
  Future<RemoteCommandResult> runOneShotCommandForBinding({
    required ConnectionTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final target = await _storageService.resolveConnectionTarget(binding);
    if (target == null) {
      if (_storageService.getConnection(binding.id) == null) {
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
  }

  void _listenToBackgroundService() {
    _cancelBackgroundSubscriptions();
    _stateSub = _backgroundService.on('sshStateChanged').listen((data) {
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

    _outputSub = _backgroundService.on('sshDataReceived').listen((data) {
      if (data == null) return;
      final String sessionId = data['sessionId'];
      final String text = data['data'];

      final session = _sessions[sessionId];
      if (session != null) {
        session.addOutput(text);
        unawaited(_historyService.append(sessionId, text));
      }
    });

    _keepAliveSub = _backgroundService.on('sshOverviewUpdated').listen((data) {
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

    _appLogSub = _backgroundService
        .on('sshLogReceived')
        .listen(handleBackgroundLog);
  }

  void _cancelBackgroundSubscriptions() {
    _stateSub?.cancel();
    _stateSub = null;
    _outputSub?.cancel();
    _outputSub = null;
    _keepAliveSub?.cancel();
    _keepAliveSub = null;
    _appLogSub?.cancel();
    _appLogSub = null;
  }

  @visibleForTesting
  void handleBackgroundLog(Map<String, dynamic>? data) {
    if (data == null) return;
    final String message = data['message'] ?? '';
    final String levelName = data['level'] ?? 'info';
    final String? details = data['details'];

    AppLogService.instance.add(
      levelName,
      '[Background] $message',
      details: details,
    );
  }

  void _refreshSessionsView() {
    _sessionsView = List.unmodifiable(
      _sessions.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );

    if (!_usesBackgroundService) {
      final byConnection = <String, SshConnectionOverview>{};
      for (final session in _sessions.values) {
        final connId = session.connectionId;
        final current = byConnection[connId];
        if (current == null) {
          byConnection[connId] = SshConnectionOverview(
            count: 1,
            latestState: session.state,
            hasConnected: session.state == SshConnectionState.connected,
          );
        } else {
          final SshConnectionState newState;
          if (current.latestState == SshConnectionState.connected ||
              session.state == SshConnectionState.connected) {
            newState = SshConnectionState.connected;
          } else if (current.latestState == SshConnectionState.connecting ||
              session.state == SshConnectionState.connecting) {
            newState = SshConnectionState.connecting;
          } else if (current.latestState == SshConnectionState.error ||
              session.state == SshConnectionState.error) {
            newState = SshConnectionState.error;
          } else {
            newState = SshConnectionState.disconnected;
          }

          byConnection[connId] = SshConnectionOverview(
            count: current.count + 1,
            latestState: newState,
            hasConnected:
                current.hasConnected ||
                session.state == SshConnectionState.connected,
          );
        }
      }
      _serverOverviewSnapshot = SshServerOverviewSnapshot(
        byConnection: byConnection,
        windowCount: _sessions.length,
      );
    }
  }

  void notify() {
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_coreSessionPool.close());
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
