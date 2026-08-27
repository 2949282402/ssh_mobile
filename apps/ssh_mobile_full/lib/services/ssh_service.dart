// ignore_for_file: prefer_initializing_formals
// Public named parameters intentionally initialize private service fields.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:app_core/app_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'package:connection_core/connection_core.dart';
import 'app_log_service.dart';
import 'app_settings.dart';
import 'background_service.dart';
import '../core/services/ssh_client_factory.dart';
import '../core/services/ssh_host_key_policy.dart';
import 'connection_target_binding.dart';
import 'remote_target_scope.dart';
import 'remote_command_decoder.dart';
import 'telemetry/telemetry_span.dart';
import 'terminal_session_metadata_store.dart' as terminal_metadata;
import 'terminal_history_service.dart';
import 'ssh/ssh_background_event_bridge.dart';
import 'ssh/ssh_connection_attempt.dart';
import '../utils/startup_instrumentation.dart';

part 'ssh/ssh_session.dart';
part 'ssh/local_ssh_runtime.dart';
part 'ssh/ssh_connection_runtime.dart';
part 'ssh/ssh_session_metadata.dart';

typedef TerminalHistoryRecord = terminal_metadata.TerminalHistoryRecord;

final class _SshServiceClosing implements Exception {
  const _SshServiceClosing();
}

/// 将 SSH Owner 的可变 session registry 投影为稳定 UI 快照。
final class _SshSessionProjection {
  const _SshSessionProjection();

  ({List<SshSession> sessions, SshServerOverviewSnapshot overview}) project(
    Iterable<SshSession> source,
  ) {
    final sessions = source.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final byConnection = <String, SshConnectionOverview>{};
    for (final session in sessions) {
      final id = session.connectionId;
      final current = byConnection[id];
      byConnection[id] = SshConnectionOverview(
        count: (current?.count ?? 0) + 1,
        latestState: _latestState(current?.latestState, session.state),
        hasConnected:
            (current?.hasConnected ?? false) ||
            session.state == SshConnectionState.connected,
      );
    }
    return (
      sessions: List<SshSession>.unmodifiable(sessions),
      overview: SshServerOverviewSnapshot(
        byConnection: byConnection,
        windowCount: sessions.length,
      ),
    );
  }

  SshConnectionState _latestState(
    SshConnectionState? current,
    SshConnectionState next,
  ) {
    const precedence = <SshConnectionState, int>{
      SshConnectionState.disconnected: 0,
      SshConnectionState.error: 1,
      SshConnectionState.connecting: 2,
      SshConnectionState.connected: 3,
    };
    if (current == null) return next;
    return precedence[next]! > precedence[current]! ? next : current;
  }
}

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
  final connection_core.ConnectionRepository _connectionRepository;
  final connection_core.CredentialRepository _credentialRepository;
  final connection_core.HostKeyRepository _hostKeyRepository;
  final terminal_metadata.TerminalSessionMetadataStore _terminalMetadataStore;
  final AppSettings? _appSettings;
  final ssh_core.SshNativeStreamConnector? _nativeStreamConnector;
  final ssh_core.SshPeerIdResolver? _peerIdResolver;
  late final SshClientFactory _clientFactory = SshClientFactory(
    credentialRepository: _credentialRepository,
    hostKeyRepository: _hostKeyRepository,
    logger: AppLogService.instance,
    nativeStreamConnector: _nativeStreamConnector,
    peerIdResolver: _peerIdResolver,
  );
  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();
  final TerminalHistoryService _historyService = TerminalHistoryService();
  final _SshSessionProjection _sessionProjection =
      const _SshSessionProjection();
  late final SshBackgroundEventBridge _backgroundBridge;

  final Map<String, SshSession> _sessions = {};
  final Map<String, ConnectionTargetBinding> _sessionTargetBindings = {};
  final Map<String, _LocalSshRuntime> _localRuntimes = {};
  final SshSessionConnectGate _localConnectGate = SshSessionConnectGate();
  // 业务遥测：连接生命周期 span 共享同一个 traceId，跨 started -> connected ->
  // terminated/failed 端到端关联。键为 sessionId。
  final Map<String, String> _telemetryTraceIds = {};
  final Map<String, DateTime> _telemetrySpanStartedAt = {};
  final Map<String, Completer<void>> _connectCompleters = {};
  final Map<String, Future<void>> _connectOperations = {};
  final Map<String, String> _connectOperationTargets = {};
  // Mobile sessions may use the legacy background isolate when their target
  // is not present in the enrolled LAN peer catalog. Keep that choice per
  // session instead of globally disabling native wiring for the whole App.
  final Map<String, bool> _sessionUsesBackgroundService = {};
  final Map<String, Future<void>> _reconnectOperations = {};
  final Set<Future<void>> _ownedSshOperations = <Future<void>>{};
  final Set<Future<void>> _persistenceOperations = <Future<void>>{};
  final Set<String> _closingSessionIds = {};
  // Step08 的共享 Pool 先挂在现有兼容 Service 上，确保 App Scope 只有一个
  // SSH Owner；Terminal Pilot 会逐步把旧方法面迁到 package Manager。
  final ssh_core.SshSessionPool _coreSessionPool = ssh_core.SshSessionPool();
  final Random _random = Random();
  List<SshSession> _sessionsView = const [];
  SshServerOverviewSnapshot _serverOverviewSnapshot =
      const SshServerOverviewSnapshot.empty();
  String? _lastSessionId;
  String? _lastErrorMessage;
  bool _restoredTmuxSessions = false;
  bool _initialized = false;
  bool _shutdownRequested = false;
  bool _notifierDisposed = false;
  final Completer<void> _shutdownSignal = Completer<void>();
  Future<void>? _initFuture;
  Future<void>? _managerCloseFuture;

  /// 可选遥测客户端；由 Composition Root 在 SSH 服务创建后注入。
  ///
  /// 业务生产者仅在客户端非空时上报，用户名/私钥/密码等敏感字段绝不写入
  /// properties；host/port 也不会出现在事件属性中，避免泄露凭据或内网地址。
  TelemetryClient? telemetryClient;

  SshService({
    required connection_core.ConnectionRepository connectionRepository,
    required connection_core.CredentialRepository credentialRepository,
    required connection_core.HostKeyRepository hostKeyRepository,
    required terminal_metadata.TerminalSessionMetadataStore
    terminalMetadataStore,
    AppSettings? appSettings,
    ssh_core.SshNativeStreamConnector? nativeStreamConnector,
    ssh_core.SshPeerIdResolver? peerIdResolver,
    this.telemetryClient,
  }) : _connectionRepository = connectionRepository,
       _credentialRepository = credentialRepository,
       _hostKeyRepository = hostKeyRepository,
       _terminalMetadataStore = terminalMetadataStore,
       _appSettings = appSettings,
       _nativeStreamConnector = nativeStreamConnector,
       _peerIdResolver = peerIdResolver {
    _backgroundBridge = SshBackgroundEventBridge(
      events: _backgroundService.on,
      onState: _handleBackgroundState,
      onOutput: _handleBackgroundOutput,
      onOverview: _handleBackgroundOverview,
      onLog: handleBackgroundLog,
    );
    StartupInstrumentation.instance.recordServiceConstructed('SshService');
  }

  @override
  bool get initialized => _initialized;

  /// 终端 Capability 由 App Composition Root 的适配器提供。
  ///
  /// 旧 Service 继续实现基础 Manager 合约，实际 Terminal 页面使用的
  /// Capability 会在 App 层包装同一个 Service，避免把旧 App 模型泄漏到
  /// Infrastructure 公共接口。
  @override
  ssh_core.SshTerminalCapability? get terminalCapability => null;

  @override
  Future<void> ensureInitialized() {
    if (_shutdownRequested) {
      return Future<void>.error(
        StateError('SshService is shutting down or already closed.'),
      );
    }
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
    if (_shutdownRequested) {
      return Future<ssh_core.SshSessionLease>.error(
        StateError('SshService is shutting down or already closed.'),
      );
    }
    return _coreSessionPool.acquire(sessionId: sessionId, create: create);
  }

  /// 关闭 App Scope SSH Manager；旧 ChangeNotifier API 由同一实例兼容承载。
  @override
  Future<void> close() {
    final existing = _managerCloseFuture;
    if (existing != null) return existing;
    _beginShutdown();
    final future = _closeManager();
    _managerCloseFuture = future;
    return future;
  }

  Future<void> _closeManager() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    final initialization = _initFuture;
    if (initialization != null) {
      await attempt(() => initialization);
    }

    // 先阻止迟到事件写回，再解除所有等待连接结果的 Future。
    await attempt(_backgroundBridge.cancel);
    for (final completer in _connectCompleters.values.toList()) {
      if (!completer.isCompleted) completer.complete();
    }
    _connectCompleters.clear();
    _closingSessionIds.addAll(_sessions.keys);
    _localConnectGate.cancelAll();

    if (_usesBackgroundService) {
      await attempt(BackgroundServiceManager.stop);
    }

    // connect/reconnect 在看到 shutdown barrier 后会回滚临时资源；等待它们
    // 完成后再关闭 registry-owned runtime，避免迟到登记越过释放边界。
    final operations = <Future<void>>[
      ..._connectOperations.values,
      ..._reconnectOperations.values,
      ..._ownedSshOperations,
    ];
    await attempt(() => Future.wait<void>(operations));
    await attempt(
      () => Future.wait<void>(_persistenceOperations.toList(growable: false)),
    );

    final runtimes = _localRuntimes.values.toList(growable: false);
    _localRuntimes.clear();
    for (final runtime in runtimes) {
      await attempt(runtime.close);
    }

    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    _sessionTargetBindings.clear();
    _sessionUsesBackgroundService.clear();
    _refreshSessionsView();
    for (final session in sessions) {
      await attempt(session.close);
    }
    _lastSessionId = null;

    // Terminal 输出写队列和共享 Pool 都属于 App Scope SSH Owner。
    await attempt(_historyService.dispose);
    await attempt(_coreSessionPool.close);
    // 关闭所有 native ReliableStream/ConnectionSession，必须在
    // networkRuntime.dispose 之前完成（app_runtime.dart 释放顺序）。
    await attempt(
      () => _nativeStreamConnector?.closeAll() ?? Future<void>.value(),
    );
    _disposeNotifier();

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void _beginShutdown() {
    if (_shutdownRequested) return;
    _shutdownRequested = true;
    if (!_shutdownSignal.isCompleted) _shutdownSignal.complete();
  }

  void _disposeNotifier() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    super.dispose();
  }

  Future<void> _doInit() async {
    try {
      StartupInstrumentation.instance.recordServiceInitialized('SshService');
      if (_usesBackgroundService) {
        await _listenToBackgroundService();
      } else {
        AppLogService.instance.info(
          'Background SSH service disabled on this platform',
        );
      }
      await restoreTmuxSessions();
      if (!_shutdownRequested) _initialized = true;
    } catch (e) {
      _initFuture = null;
      rethrow;
    }
  }

  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// The background bridge stays available on mobile for un-enrolled targets;
  /// the actual transport is selected after resolving the current config.
  bool get _usesBackgroundService => _isMobilePlatform;

  String? _resolvePeerId(ConnectionConfig config) {
    final peerId = _peerIdResolver?.call(config)?.trim();
    return peerId == null || peerId.isEmpty ? null : peerId;
  }

  bool _usesBackgroundForSession(String sessionId) =>
      _sessionUsesBackgroundService[sessionId] ?? _usesBackgroundService;

  /// 是否已配置 native ReliableStream 传输（连接器 + peer 绑定解析器）。
  bool get _canUseNativeTransport =>
      _nativeStreamConnector != null && _peerIdResolver != null;

  /// Test/diagnostic observation that the App composition root supplied both
  /// native transport halves. Individual configs can still use the documented
  /// raw-TCP/background fallback when no enrolled peer binding exists.
  @visibleForTesting
  bool get canUseNativeTransport => _canUseNativeTransport;

  @override
  List<SshSession> get sessions => _sessionsView;

  /// 当前处于连接中或已连接状态的会话数量，供诊断页面读取。
  int get activeSessionCount => _sessions.values
      .where(
        (session) =>
            session.state == SshConnectionState.connecting ||
            session.state == SshConnectionState.connected,
      )
      .length;

  /// 当前已登记但不处于连接中/已连接状态的会话数量。
  int get idleSessionCount => _sessions.length - activeSessionCount;

  /// App Scope SSH Pool 当前仍被消费者持有的租约数量。
  int get leaseCount => _coreSessionPool.activeLeaseCount;

  /// SSH Service 当前已登记的后台事件订阅数量。
  int get activeSubscriptionCount => _backgroundBridge.activeSubscriptionCount;

  /// SSH Pool 当前等待空闲回收的 Timer 数量。
  int get activeTimerCount => _coreSessionPool.idleTimerCount;

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

  ConnectionTargetBinding? _captureConnectionTargetBinding(String id) {
    final config = _connectionRepository.getConnection(id);
    return config == null ? null : ConnectionTargetBinding.fromConfig(config);
  }

  @override
  Future<String> loadSessionHistoryText(String sessionId) {
    return _historyService.readTail(sessionId);
  }

  @override
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() {
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

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) {
    return _terminalMetadataStore.removeTerminalHistoryRecord(sessionId);
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
    _schedulePersistence(
      () => _saveRestorableTmuxSession(session),
      description: 'Failed to save restorable SSH session',
    );
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
    _schedulePersistence(
      () => _saveRestorableTmuxSession(session),
      description: 'Failed to save restorable SSH session',
    );
    _notifySessionMetadataChanged();
  }

  @override
  Future<void> restoreTmuxSessions() async {
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
  }) {
    if (_shutdownRequested) {
      return Future<void>.error(
        StateError('SshService is shutting down or already closed.'),
      );
    }
    final id = sessionId ?? _createSessionId(connectionId);
    final existing = _connectOperations[id];
    if (existing != null) {
      if (_connectOperationTargets[id] != connectionId) {
        return Future<void>.error(
          StateError(
            'SSH session $id is already connecting to a different target.',
          ),
        );
      }
      return existing;
    }

    late final Future<void> operation;
    operation =
        _connectOnce(
          connectionId,
          sessionId: id,
          displayName: displayName,
          onUnknownHostKey: onUnknownHostKey,
        ).whenComplete(() {
          if (identical(_connectOperations[id], operation)) {
            _connectOperations.remove(id);
            _connectOperationTargets.remove(id);
          }
        });
    _connectOperations[id] = operation;
    _connectOperationTargets[id] = connectionId;
    return operation;
  }

  Future<void> _connectOnce(
    String connectionId, {
    required String sessionId,
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final id = sessionId;
    ConnectionRuntimeTarget runtimeTarget;
    try {
      await Future<void>.delayed(Duration.zero);
      if (_shutdownRequested) return;
      runtimeTarget = await RemoteTargetScope.resolveIfBound(
        connectionRepository: _connectionRepository,
        credentialRepository: _credentialRepository,
        connectionId: connectionId,
      );
    } on RemoteTargetScopeException catch (e) {
      if (_shutdownRequested) return;
      AppLogService.instance.error(
        'SSH connection target unavailable',
        error: e,
        details: 'connectionId=$connectionId sessionId=$id code=${e.code}',
      );
      await _setSessionError(id, connectionId, 'Unknown', e.message);
      return;
    }
    if (_shutdownRequested) return;
    final config = runtimeTarget.config;
    final resolvedPeerId = _resolvePeerId(config);
    final usesBackgroundService = _isMobilePlatform && resolvedPeerId == null;
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
      await _setSessionError(
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
      await _setSessionError(
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
    _sessionUsesBackgroundService[id] = usesBackgroundService;
    session.state = SshConnectionState.connecting;
    session.errorMessage = null;
    session.tmuxAutoDeleteSeconds = config.tmuxAutoDeleteSeconds;
    session.updatedAt = DateTime.now();
    _lastErrorMessage = null;
    _lastSessionId = id;
    await _startSessionTelemetry(session, config);
    final traceId = _telemetryTraceIds[id];
    final launchMode = _effectiveLaunchMode(config);
    final connectCompleter = Completer<void>();
    _connectCompleters[id] = connectCompleter;
    _schedulePersistence(
      () => _saveTerminalHistoryRecord(session),
      description: 'Failed to save terminal history record',
    );
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
      if (_shutdownRequested) throw const _SshServiceClosing();

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
      if (usesBackgroundService) {
        if (config.hostKeyFingerprint?.isNotEmpty != true) {
          await _verifyHostKeyBeforeBackground(
            config: config,
            credentials: credentials,
            onUnknownHostKey: onUnknownHostKey,
            traceId: traceId,
            peerId: resolvedPeerId,
          );
        }
        await BackgroundServiceManager.start(
          connectionName: _notificationSummary(),
          showConnectionName:
              _appSettings?.showServerNamesInNotifications ?? false,
        );
        // Let the UI render while foreground service is starting up
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (_shutdownRequested) throw const _SshServiceClosing();
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
          'peerId': resolvedPeerId,
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
        if (_shutdownRequested) throw const _SshServiceClosing();
        await _connectLocalSession(
          session: session,
          config: config,
          credentials: credentials,
          launchMode: launchMode,
          onUnknownHostKey: onUnknownHostKey,
          peerId: resolvedPeerId,
          traceId: traceId,
        );
      }

      await connectCompleter.future.timeout(const Duration(seconds: 30));
      if (_shutdownRequested) throw const _SshServiceClosing();
    } on _SshServiceClosing {
      final pending = _connectCompleters.remove(id);
      if (pending != null && !pending.isCompleted) pending.complete();
    } on TimeoutException {
      if (_shutdownRequested) return;
      final pending = _connectCompleters.remove(id);
      if (pending != null && !pending.isCompleted) pending.complete();
      AppLogService.instance.error(
        'Session connect timed out',
        details: 'sessionId=$id connection=${config.name}',
      );
      await _failSessionTelemetry(
        _sessions[id] ?? session,
        'connect',
        errorCode: TelemetryErrorCodes.sshTimeout,
        errorMessage: 'Connection timed out',
      );
      await _setSessionError(
        id,
        connectionId,
        config.name,
        'Connection timed out',
      );
    } catch (e, stackTrace) {
      if (_shutdownRequested) return;
      final pending = _connectCompleters.remove(id);
      if (pending != null && !pending.isCompleted) pending.complete();
      AppLogService.instance.error(
        'Session connect failed',
        error: e,
        stackTrace: stackTrace,
        details: 'sessionId=$id connection=${config.name}',
      );
      final errorCode = _mapSshErrorCode(e, config);
      await _failSessionTelemetry(
        _sessions[id] ?? session,
        'connect',
        errorCode: errorCode,
        errorMessage: '$e',
      );
      await _setSessionError(
        id,
        connectionId,
        config.name,
        'Connection failed: $e',
      );
    }
  }

  @override
  Future<void> disconnectSession(String sessionId) async {
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

  @override
  Future<void> disconnect() async {
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

  @override
  void resizeTerminal(String sessionId, int width, int height) {
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

  @override
  void sendData(String sessionId, String data) {
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
  Future<RemoteCommandResult> runOneShotCommandForBinding({
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

  Future<void> _listenToBackgroundService() => _backgroundBridge.start();

  void _handleBackgroundState(Map<String, dynamic> data) {
    if (_shutdownRequested) return;
    final String sessionId = data['sessionId'];
    final String stateName = data['state'];
    final String? error = data['errorMessage'];
    final state = SshConnectionState.values.firstWhere(
      (candidate) => candidate.name == stateName,
      orElse: () => SshConnectionState.disconnected,
    );

    final session = _sessions[sessionId];
    if (session == null) return;
    session.state = state;
    session.errorMessage = error;
    session.updatedAt = DateTime.now();

    if (state == SshConnectionState.connected) {
      unawaited(
        _completeBackgroundConnectAfterTelemetry(
          sessionId,
          _recordSessionConnectedTelemetry(session),
        ),
      );
    } else if (state == SshConnectionState.error) {
      unawaited(
        _completeBackgroundFailureAfterTelemetry(
          sessionId,
          _failSessionTelemetry(
            session,
            'connect',
            errorCode: _mapBackgroundErrorCode(error),
            errorMessage: error ?? 'Connection failed',
          ),
          error ?? 'Connection failed',
        ),
      );
    }

    _schedulePersistence(
      () => _saveTerminalHistoryRecord(session),
      description: 'Failed to save terminal history record',
    );
    _notifySessionMetadataChanged();
  }

  Future<void> _completeBackgroundConnectAfterTelemetry(
    String sessionId,
    Future<void> telemetry,
  ) async {
    try {
      await telemetry;
    } on Object {
      // The telemetry producer already treats storage errors as best effort;
      // keep this guard at the completion boundary for custom clients.
    }
    final completer = _connectCompleters.remove(sessionId);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _completeBackgroundFailureAfterTelemetry(
    String sessionId,
    Future<void> telemetry,
    String message,
  ) async {
    try {
      await telemetry;
    } on Object {
      // The telemetry producer already treats storage errors as best effort;
      // preserve the original SSH failure regardless of local telemetry state.
    }
    final completer = _connectCompleters.remove(sessionId);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError(message));
    }
  }

  void _handleBackgroundOutput(Map<String, dynamic> data) {
    if (_shutdownRequested) return;
    final String sessionId = data['sessionId'];
    final String text = data['data'];
    final session = _sessions[sessionId];
    if (session == null) return;
    session.addOutput(text);
    unawaited(_historyService.append(sessionId, text));
  }

  void _handleBackgroundOverview(Map<String, dynamic> data) {
    if (_shutdownRequested) return;
    final overviewMap = data['overview'] as Map;
    final windowCount = data['windowCount'] as int;
    final byConnection = <String, SshConnectionOverview>{};
    for (final entry in overviewMap.entries) {
      final val = entry.value as Map;
      final latestStateName = val['latestState'] as String?;
      final state = latestStateName == null
          ? null
          : SshConnectionState.values.firstWhere(
              (candidate) => candidate.name == latestStateName,
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
    notify();
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
    final projection = _sessionProjection.project(_sessions.values);
    _sessionsView = projection.sessions;
    if (!_sessionUsesBackgroundService.values.any((uses) => uses)) {
      _serverOverviewSnapshot = projection.overview;
    }
  }

  void notify() {
    if (!_shutdownRequested && !_notifierDisposed) notifyListeners();
  }

  void _schedulePersistence(
    Future<void> Function() operation, {
    required String description,
  }) {
    if (_shutdownRequested) return;
    late final Future<void> tracked;
    tracked = operation()
        .catchError((Object error, StackTrace stackTrace) {
          AppLogService.instance.error(
            description,
            error: error,
            stackTrace: stackTrace,
          );
        })
        .whenComplete(() => _persistenceOperations.remove(tracked));
    _persistenceOperations.add(tracked);
    unawaited(tracked);
  }

  Future<T> _trackOwnedSshOperation<T>(Future<T> Function() operation) {
    if (_shutdownRequested) {
      return Future<T>.error(
        StateError('SshService is shutting down or already closed.'),
      );
    }
    final result = Future<T>.sync(operation);
    late final Future<void> barrier;
    barrier = result
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() => _ownedSshOperations.remove(barrier));
    _ownedSshOperations.add(barrier);
    return result;
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    final shutdown = close();
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
    unawaited(
      shutdown.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          AppLogService.instance.error(
            'SshService asynchronous dispose failed',
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );
  }
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
