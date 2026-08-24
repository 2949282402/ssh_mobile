// Monitoring Feature 使用的 App/Infrastructure Port。

import 'package:connection_core/connection_core.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

/// 监控请求的调度优先级。
///
/// 监控只允许使用低优先级，避免与交互 Terminal 共用调度入口时抢占用户
/// 正在操作的会话。具体队列由 App Shell 的 SSH 适配器负责执行。
enum MonitoringRequestPriority { low }

/// 监控执行只读 SSH exec 的能力契约。
abstract interface class MonitoringSshPort {
  /// 按当前连接配置执行低优先级命令。
  Future<ssh_core.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    MonitoringRequestPriority priority = MonitoringRequestPriority.low,
  });

  /// 按审批时的不可变目标快照执行低优先级命令。
  Future<ssh_core.RemoteCommandResult> runOneShotCommandForBinding({
    required ssh_core.SshTargetBinding binding,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    MonitoringRequestPriority priority = MonitoringRequestPriority.low,
  });
}

/// 监控查询连接目标平台的最小能力。
abstract interface class MonitoringConnectionCatalogPort {
  /// 捕获当前保存配置的不可变 SSH 目标；连接不存在时返回 null。
  ssh_core.SshTargetBinding? targetBindingFor(String connectionId);

  /// 返回保存的服务器平台；未知连接返回 null，由监控服务按 Linux 兼容处理。
  ServerPlatform? serverPlatformFor(String connectionId);
}

/// 监控日志能力，避免 Feature 访问 AppLogService 静态单例。
abstract interface class MonitoringLoggerPort {
  /// 记录可恢复的监控异常或重试。
  void warning(String message, {String? details});

  /// 记录监控异常和堆栈。
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}

/// 监控使用的前台服务能力。
abstract interface class MonitoringBackgroundPort {
  /// 监控开始后请求保持前台运行能力。
  Future<void> start({required String connectionName});
}
