// Desktop SSH Runtime 的注入式适配器。
//
// 具体 dartssh2 本地连接由 App 组合根提供回调；该类不在 Feature 中创建
// Socket，也不自行判断 Platform，从而让桌面资源的 Owner 和生命周期可测试。

import 'dart:async';

import '../model/ssh_runtime_event.dart';
import 'ssh_runtime_adapter.dart';

/// 桌面端本地 SSH Runtime。
final class DesktopSshRuntime implements SshRuntimeAdapter {
  /// 创建桌面 Runtime。
  DesktopSshRuntime({this.initialize, this.onDispose, this.eventsFactory});

  /// 初始化桌面底层资源的回调。
  final Future<void> Function()? initialize;

  /// 释放桌面底层资源的回调。
  final Future<void> Function()? onDispose;

  /// 提供桌面事件流的回调。
  final Stream<SshRuntimeEvent> Function()? eventsFactory;

  late final Stream<SshRuntimeEvent> _events =
      eventsFactory?.call() ?? const Stream<SshRuntimeEvent>.empty();
  Future<void>? _initialization;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  bool get supportsBackgroundService => false;

  @override
  Stream<SshRuntimeEvent> get events => _events;

  @override
  Future<void> ensureInitialized() {
    if (_disposed) {
      return Future<void>.error(StateError('Desktop SSH Runtime is disposed.'));
    }
    final existing = _initialization;
    if (existing != null) return existing;
    final future = initialize?.call() ?? Future<void>.value();
    _initialization = future;
    future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        if (identical(_initialization, future)) _initialization = null;
      },
    );
    return future;
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    if (_disposed) return Future<void>.value();
    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    final initializing = _initialization;
    if (initializing != null) await initializing;
    await onDispose?.call();
  }
}
