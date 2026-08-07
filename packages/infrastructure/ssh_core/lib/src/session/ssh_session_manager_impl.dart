// SSH Session Manager 默认实现。
//
// 该实现把 Runtime 初始化和 Session Pool 绑定到同一 App Scope Owner，失败
// 时清理 in-flight 状态允许重试，关闭时等待所有连接和输出流完成释放。

import 'dart:async';

import '../model/ssh_session.dart';
import '../pool/ssh_session_lease.dart';
import '../pool/ssh_session_pool.dart';
import '../runtime/ssh_runtime_adapter.dart';
import 'ssh_session_manager.dart';

/// SSH Manager 的内部生命周期状态。
enum SshSessionManagerState { idle, starting, ready, stopping, disposed }

/// 使用注入式 Runtime 的 SSH Session Manager。
final class SshSessionManagerImpl implements SshSessionManager {
  /// 创建 SSH Manager。
  SshSessionManagerImpl({required this.runtime, SshSessionPool? sessionPool})
    : _sessionPool = sessionPool ?? SshSessionPool();

  /// 注入的桌面或移动端 Runtime。
  final SshRuntimeAdapter runtime;
  final SshSessionPool _sessionPool;
  SshSessionManagerState _state = SshSessionManagerState.idle;
  Future<void>? _initialization;
  Future<void>? _closeFuture;

  /// 当前生命周期状态。
  SshSessionManagerState get state => _state;

  @override
  bool get initialized => _state == SshSessionManagerState.ready;

  @override
  Future<void> ensureInitialized() {
    if (_state == SshSessionManagerState.disposed) {
      return Future<void>.error(
        StateError('SSH Session Manager has been disposed.'),
      );
    }
    if (initialized) return Future<void>.value();
    final existing = _initialization;
    if (existing != null) return existing;

    _state = SshSessionManagerState.starting;
    final future = runtime.ensureInitialized();
    _initialization = future;
    future.then<void>(
      (_) {
        if (!identical(_initialization, future)) return;
        _initialization = null;
        if (_state != SshSessionManagerState.disposed) {
          _state = SshSessionManagerState.ready;
        }
      },
      onError: (Object _, StackTrace _) {
        if (!identical(_initialization, future)) return;
        _initialization = null;
        if (_state != SshSessionManagerState.disposed) {
          _state = SshSessionManagerState.idle;
        }
      },
    );
    return future;
  }

  @override
  Future<SshSessionLease> acquire({
    required String sessionId,
    required Future<SshSession> Function() create,
  }) async {
    await ensureInitialized();
    return _sessionPool.acquire(sessionId: sessionId, create: create);
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    if (_state == SshSessionManagerState.disposed) {
      return Future<void>.value();
    }
    _state = SshSessionManagerState.stopping;
    final future = _closeResources();
    _closeFuture = future;
    return future;
  }

  Future<void> _closeResources() async {
    final initializing = _initialization;
    if (initializing != null) {
      try {
        await initializing;
      } catch (_) {
        // 初始化失败时仍需继续释放 Runtime 和 Pool。
      }
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _sessionPool.close();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await runtime.dispose();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _state = SshSessionManagerState.disposed;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}
