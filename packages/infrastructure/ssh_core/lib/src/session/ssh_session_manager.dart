// SSH Session Manager 的 App Scope 公共契约。
//
// Feature 只依赖这个接口，不创建 SshClient、Background Service 或 Session
// Pool。Manager 的唯一实例由 AppRuntime 持有并负责最终 close。

import '../model/ssh_session.dart';
import '../pool/ssh_session_lease.dart';

/// SSH Session Manager 生命周期与共享会话契约。
abstract interface class SshSessionManager {
  /// 运行时是否已经完成初始化。
  bool get initialized;

  /// 初始化底层 Runtime；相同时间内的调用必须共享一个 Future。
  Future<void> ensureInitialized();

  /// 获取一个共享会话的消费者租约。
  Future<SshSessionLease> acquire({
    required String sessionId,
    required Future<SshSession> Function() create,
  });

  /// 关闭 Manager 拥有的 Session、Runtime 和监听资源。
  Future<void> close();
}
