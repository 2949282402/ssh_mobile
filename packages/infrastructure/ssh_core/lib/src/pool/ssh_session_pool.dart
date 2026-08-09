// SSH Session Pool 生命周期实现。
//
// Pool 负责并发 acquire 合并、引用计数、idle Timer 和最终 Stream close。
// Feature 永远拿不到关闭共享 Session 的权限，只能释放自己的 Lease。

import 'dart:async';

import '../model/ssh_session.dart';
import 'ssh_session_lease.dart';

/// 创建一个新共享会话的回调。
typedef SshSessionCreator = Future<SshSession> Function();

/// App Scope SSH Session 的引用计数池。
final class SshSessionPool {
  /// 创建 Session Pool。
  SshSessionPool({this.idleTimeout = const Duration(minutes: 2)})
    : assert(!idleTimeout.isNegative);

  /// 引用归零后等待多久再关闭会话。
  final Duration idleTimeout;
  final Map<String, _PoolEntry> _entries = <String, _PoolEntry>{};
  bool _closed = false;
  Future<void>? _closeFuture;

  /// 当前已登记的 Session 数量。
  int get length => _entries.length;

  /// 当前仍被消费者持有的引用总数。
  int get activeLeaseCount =>
      _entries.values.fold<int>(0, (total, entry) => total + entry.refCount);

  /// 当前已安排空闲清理的 Session 数量。
  ///
  /// 该计数只用于诊断和生命周期验证，不允许调用方据此直接关闭 Session；
  /// 真正的清理仍由 Pool 的 idle Timer Owner 执行。
  int get idleTimerCount =>
      _entries.values.where((entry) => entry.idleTimer != null).length;

  /// 获取一个共享 Session 的消费者租约。
  ///
  /// 相同 [sessionId] 的并发创建共享同一个 Future；创建失败会移除坏的
  /// Entry，使下一次 acquire 可以重试。
  Future<SshSessionLease> acquire({
    required String sessionId,
    required SshSessionCreator create,
  }) async {
    _ensureUsable();
    final entry = _entries.putIfAbsent(sessionId, _PoolEntry.new);
    entry.idleTimer?.cancel();
    entry.idleTimer = null;

    final session = await _ensureSession(sessionId, entry, create);
    if (_closed) {
      await session.close();
      throw StateError('SSH Session Pool has been closed.');
    }
    entry.refCount++;
    return SshSessionLease(
      session: session,
      releaseCallback: () => _release(sessionId, entry),
    );
  }

  Future<SshSession> _ensureSession(
    String sessionId,
    _PoolEntry entry,
    SshSessionCreator create,
  ) {
    final existing = entry.session;
    if (existing != null) return Future<SshSession>.value(existing);
    final initializing = entry.initialization;
    if (initializing != null) return initializing;

    final future = create();
    entry.initialization = future;
    future.then<void>(
      (session) {
        if (identical(entry.initialization, future)) {
          entry.initialization = null;
          entry.session = session;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(entry.initialization, future)) {
          entry.initialization = null;
          if (identical(_entries[sessionId], entry)) _entries.remove(sessionId);
        }
      },
    );
    return future;
  }

  Future<void> _release(String sessionId, _PoolEntry entry) async {
    if (entry.refCount == 0) return;
    entry.refCount--;
    if (entry.refCount != 0 || _closed) return;

    if (idleTimeout == Duration.zero) {
      await _closeIdleEntry(sessionId, entry);
      return;
    }
    entry.idleTimer = Timer(
      idleTimeout,
      () => unawaited(_closeIdleEntry(sessionId, entry)),
    );
  }

  Future<void> _closeIdleEntry(String sessionId, _PoolEntry entry) async {
    if (entry.refCount != 0 || !identical(_entries[sessionId], entry)) return;
    entry.idleTimer?.cancel();
    entry.idleTimer = null;
    _entries.remove(sessionId);
    final session = entry.session;
    entry.session = null;
    if (session != null) await session.close();
  }

  /// 关闭所有 Session、Timer 和等待中的创建任务；重复调用幂等。
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    if (_closed) return Future<void>.value();
    _closed = true;
    final future = _closeAll();
    _closeFuture = future;
    return future;
  }

  Future<void> _closeAll() async {
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    for (final entry in entries) {
      entry.idleTimer?.cancel();
      entry.idleTimer = null;
      SshSession? session = entry.session;
      if (session == null) {
        final initializing = entry.initialization;
        if (initializing != null) {
          try {
            session = await initializing;
          } catch (_) {
            session = null;
          }
        }
      }
      if (session != null) await session.close();
    }
  }

  void _ensureUsable() {
    if (_closed) throw StateError('SSH Session Pool has been closed.');
  }
}

final class _PoolEntry {
  SshSession? session;
  Future<SshSession>? initialization;
  Timer? idleTimer;
  int refCount = 0;
}
