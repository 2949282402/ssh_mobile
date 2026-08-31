part of '../ssh_service.dart';

/// Owns lazy initialization, shutdown barriers, and platform transport choice.
extension _SshServiceLifecycle on SshService {
  Future<void> _ensureInitialized() {
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
    _backgroundOverviewSnapshot = null;
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
}
