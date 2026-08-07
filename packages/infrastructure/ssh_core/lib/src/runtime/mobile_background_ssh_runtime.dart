// 移动端 Background SSH Runtime 的注入式适配器。
//
// flutter_background_service、通知和电源锁只应在 App 层实现回调中出现；
// Session Manager 通过这个契约使用它们，不把平台 SDK 泄漏到 Feature。

import 'dart:async';

import '../model/ssh_runtime_event.dart';
import 'ssh_runtime_adapter.dart';

/// 移动端后台 SSH Runtime。
final class MobileBackgroundSshRuntime implements SshRuntimeAdapter {
  /// 创建移动端 Runtime。
  MobileBackgroundSshRuntime({
    required this.initialize,
    required this.onDispose,
    required this.eventStream,
  });

  /// 初始化移动端后台资源的回调。
  final Future<void> Function() initialize;

  /// 释放后台服务、通知和电源锁的回调。
  final Future<void> Function() onDispose;

  /// 已由 App 层转译的平台事件流。
  final Stream<SshRuntimeEvent> eventStream;
  Future<void>? _initialization;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  bool get supportsBackgroundService => true;

  @override
  Stream<SshRuntimeEvent> get events => eventStream;

  @override
  Future<void> ensureInitialized() {
    if (_disposed) {
      return Future<void>.error(
        StateError('Mobile background SSH Runtime is disposed.'),
      );
    }
    final existing = _initialization;
    if (existing != null) return existing;
    final future = initialize();
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
    await onDispose();
  }
}
