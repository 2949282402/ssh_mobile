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
part 'ssh/ssh_service_lifecycle.dart';
part 'ssh/ssh_service_session_actions.dart';
part 'ssh/ssh_service_connection.dart';
part 'ssh/ssh_service_commands.dart';
part 'ssh/ssh_service_background.dart';
part 'ssh/ssh_service_overview.dart';
part 'ssh/ssh_service_operations.dart';

typedef TerminalHistoryRecord = terminal_metadata.TerminalHistoryRecord;

final class _SshServiceClosing implements Exception {
  const _SshServiceClosing();
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
  final SshClientFactory? _clientFactoryOverride;
  final Duration Function(int attempt)? _reconnectDelayOverride;
  final Timer Function(Duration, void Function(Timer))? _timerFactoryOverride;
  late final SshClientFactory _clientFactory =
      _clientFactoryOverride ??
      SshClientFactory(
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
  SshServerOverviewSnapshot? _backgroundOverviewSnapshot;
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
    @visibleForTesting SshClientFactory? clientFactory,
    @visibleForTesting Duration Function(int attempt)? reconnectDelay,
    @visibleForTesting
    Timer Function(Duration, void Function(Timer))? timerFactory,
    this.telemetryClient,
  }) : _connectionRepository = connectionRepository,
       _credentialRepository = credentialRepository,
       _hostKeyRepository = hostKeyRepository,
       _terminalMetadataStore = terminalMetadataStore,
       _appSettings = appSettings,
       _nativeStreamConnector = nativeStreamConnector,
       _peerIdResolver = peerIdResolver,
       _clientFactoryOverride = clientFactory,
       _reconnectDelayOverride = reconnectDelay,
       _timerFactoryOverride = timerFactory {
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
    return _ensureInitialized();
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

  void _disposeNotifier() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    super.dispose();
  }

  void _handleBackgroundState(Map<String, dynamic> data) =>
      _handleBackgroundStateEvent(data);

  void _handleBackgroundOutput(Map<String, dynamic> data) =>
      _handleBackgroundOutputEvent(data);

  void _handleBackgroundOverview(Map<String, dynamic> data) =>
      _handleBackgroundOverviewEvent(data);

  Future<void> _listenToBackgroundService() => _startBackgroundBridge();

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
  Future<String> loadSessionHistoryText(String sessionId) =>
      _loadSessionHistoryText(sessionId);

  @override
  Future<List<TerminalHistoryRecord>> loadTerminalHistoryRecords() =>
      _loadTerminalHistoryRecords();

  @override
  Future<void> removeTerminalHistoryRecord(String sessionId) =>
      _removeTerminalHistoryRecord(sessionId);

  @override
  bool hasConnectedSession(String connectionId) =>
      _hasConnectedSession(connectionId);

  @override
  SshSession? latestSessionForConnection(String connectionId) =>
      _latestSessionForConnection(connectionId);

  @override
  int sessionCountForConnection(String connectionId) =>
      _sessionCountForConnection(connectionId);

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) =>
      _disconnectSessionsForConnection(connectionId);

  @override
  bool renameSession(String sessionId, String name) =>
      _renameSession(sessionId, name);

  @override
  void setSessionFontSize(String sessionId, double fontSize) =>
      _setSessionFontSize(sessionId, fontSize);

  @override
  Future<void> restoreTmuxSessions() => _restoreTmuxSessions();

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) => _openSession(
    connectionId,
    displayName: displayName,
    onUnknownHostKey: onUnknownHostKey,
  );

  @override
  Future<bool> ensureSessionConnected(String sessionId, String connectionId) =>
      _ensureSessionConnected(sessionId, connectionId);

  @override
  Future<bool> ensureConnected(String connectionId) =>
      _ensureConnected(connectionId);

  @override
  Future<void> connect(
    String connectionId, {
    String? sessionId,
    String? displayName,
    SshHostKeyConfirmation? onUnknownHostKey,
  }) => _connectSession(
    connectionId,
    sessionId: sessionId,
    displayName: displayName,
    onUnknownHostKey: onUnknownHostKey,
  );
  @override
  Future<void> disconnectSession(String sessionId) =>
      _disconnectSession(sessionId);

  @override
  Future<void> disconnect() => _disconnectAll();

  @override
  void resizeTerminal(String sessionId, int width, int height) =>
      _resizeTerminal(sessionId, width, height);

  @override
  void sendData(String sessionId, String data) => _sendData(sessionId, data);

  @override
  void sendBytes(String sessionId, Uint8List data) =>
      _sendBytes(sessionId, data);

  /// 执行单次 SSH 命令并返回结果。
  /// AI 工具和诊断场景使用此方法，通过普通 SSH exec 执行（非 tmux）。
  /// 不复用交互式终端会话，每条命令独立连接，用完即关。
  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) => _runOneShotCommand(
    connectionId: connectionId,
    command: command,
    timeout: timeout,
    onUnknownHostKey: onUnknownHostKey,
  );

  /// Executes against an explicitly approved target binding.
  Future<RemoteCommandResult> runOneShotCommandForBinding({
    required ConnectionTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) => _runOneShotCommandForBinding(
    binding: binding,
    command: command,
    timeout: timeout,
    onUnknownHostKey: onUnknownHostKey,
  );
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

  void _refreshSessionsView() => _refreshSessionsViewState();
  void _schedulePersistence(
    Future<void> Function() operation, {
    required String description,
  }) => _schedulePersistenceOperation(operation, description: description);

  Future<T> _trackOwnedSshOperation<T>(Future<T> Function() operation) =>
      _trackSshOperation(operation);

  void notify() {
    if (!_shutdownRequested && !_notifierDisposed) notifyListeners();
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
