// SSH 平台 Runtime 适配器契约。
//
// Desktop 和移动端的 Socket/Background 实现通过该接口注入。Feature 不得
// 直接判断平台或导入 flutter_background_service；资源释放由 App Scope Owner
// 统一调用 [dispose]。

import '../model/ssh_runtime_event.dart';

/// SSH Runtime 的平台无关生命周期和事件边界。
abstract interface class SshRuntimeAdapter {
  /// 当前实现是否依赖移动端 Background Service。
  bool get supportsBackgroundService;

  /// 初始化平台资源；并发调用由 Session Manager 合并。
  Future<void> ensureInitialized();

  /// 监听平台层转译后的 SSH 事件。
  Stream<SshRuntimeEvent> get events;

  /// 释放 Timer、Subscription、Background 句柄和其他平台资源。
  Future<void> dispose();
}
