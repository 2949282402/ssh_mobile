// Monitoring Package 单元测试使用的可控 Port 实现。

import 'package:connection_core/connection_core.dart';
import 'package:feature_monitoring/feature_monitoring.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

/// 记录监控请求并返回固定 Windows 快照的 SSH Fake。
final class FakeMonitoringSshPort implements MonitoringSshPort {
  int callCount = 0;
  MonitoringRequestPriority? lastPriority;

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    MonitoringRequestPriority priority = MonitoringRequestPriority.low,
  }) async {
    callCount += 1;
    lastPriority = priority;
    return _windowsResult;
  }

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommandForBinding({
    required ssh_core.SshTargetBinding binding,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    MonitoringRequestPriority priority = MonitoringRequestPriority.low,
  }) {
    return runOneShotCommand(
      connectionId: binding.id,
      command: command,
      timeout: timeout,
      onUnknownHostKey: onUnknownHostKey,
      priority: priority,
    );
  }

  static const _windowsResult = ssh_core.RemoteCommandResult(
    exitCode: 0,
    stdout:
        '{"cpuPercent":12,"memoryPercent":34,"diskBytesPerSecond":5,'
        '"networkBytesPerSecond":6,"disks":[],"ports":[],'
        '"applications":[],"services":[]}',
    stderr: '',
  );
}

/// 返回固定服务器平台的连接目录 Fake。
final class FakeMonitoringConnectionCatalog
    implements MonitoringConnectionCatalogPort {
  FakeMonitoringConnectionCatalog({this.platform = ServerPlatform.windows});

  ServerPlatform? platform;

  @override
  ServerPlatform? serverPlatformFor(String connectionId) => platform;
}

/// 不输出内容的日志 Fake。
final class FakeMonitoringLogger implements MonitoringLoggerPort {
  final List<String> warnings = [];
  final List<String> errors = [];

  @override
  void warning(String message, {String? details}) {
    warnings.add(details == null ? message : '$message: $details');
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    errors.add(details == null ? message : '$message: $details');
  }
}

/// 记录前台服务启动次数的 Fake。
final class FakeMonitoringBackground implements MonitoringBackgroundPort {
  int startCount = 0;

  @override
  Future<void> start({required String connectionName}) async {
    startCount += 1;
  }
}
