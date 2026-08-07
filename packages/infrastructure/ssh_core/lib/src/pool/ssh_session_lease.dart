// SSH Session Pool 的消费者租约。
//
// Lease 是 Feature 使用共享会话的唯一释放边界。重复 release 安全，真正的
// Session close 只能由 Pool 在引用归零且 idle timeout 到期后执行。

import '../model/ssh_session.dart';

/// 一个消费者对共享 SSH 会话的短生命周期引用。
final class SshSessionLease {
  /// 由 Session Pool 创建租约。
  ///
  /// [onRelease] 是内部回调；业务代码只应调用 [release]，不应保存或复制
  /// Pool 的实现细节。
  SshSessionLease({required this.session, required this.releaseCallback});

  /// 被共享的 SSH 会话。
  final SshSession session;

  /// Pool 注入的幂等释放回调；业务代码应优先调用 [release]。
  final Future<void> Function() releaseCallback;
  Future<void>? _releaseFuture;

  /// 当前租约是否已经交还。
  bool get isReleased => _releaseFuture != null;

  /// 交还租约；重复调用返回第一次交还的 Future。
  Future<void> release() {
    final existing = _releaseFuture;
    if (existing != null) return existing;
    final future = releaseCallback();
    _releaseFuture = future;
    return future;
  }
}
