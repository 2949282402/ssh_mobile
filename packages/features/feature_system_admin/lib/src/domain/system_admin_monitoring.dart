// System Admin 使用的监控 Capability Contract。
//
// 这里仅声明展示和快照所需的数据，不导入 feature_monitoring。App Shell
// 负责把 Monitoring 实现转换为这些不可变 DTO，避免 Feature 间实现耦合。

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

/// 监控健康等级的本地展示枚举。
enum ServerHealthLevel { unknown, healthy, warning, critical }

/// 性能历史中的单个样本。
final class PerformanceSample {
  const PerformanceSample({
    required this.connectionId,
    required this.time,
    required this.cpuPercent,
    required this.memoryPercent,
    required this.diskBytesPerSecond,
    required this.networkBytesPerSecond,
  });

  final String connectionId;
  final DateTime time;
  final double cpuPercent;
  final double memoryPercent;
  final double diskBytesPerSecond;
  final double networkBytesPerSecond;
}

/// 服务器健康摘要。
final class ServerHealthSnapshot {
  const ServerHealthSnapshot({
    required this.connectionId,
    required this.level,
    required this.score,
    required this.summary,
    required this.details,
    required this.updatedAt,
  });

  final String connectionId;
  final ServerHealthLevel level;
  final int score;
  final String summary;
  final List<String> details;
  final DateTime updatedAt;
}

/// 监控告警摘要。
final class MonitorAlert {
  const MonitorAlert({
    required this.id,
    required this.connectionId,
    required this.metric,
    required this.level,
    required this.message,
    required this.createdAt,
  });

  final String id;
  final String connectionId;
  final String metric;
  final ServerHealthLevel level;
  final String message;
  final DateTime createdAt;
}

/// 磁盘容量摘要。
final class DiskUsageSnapshot {
  const DiskUsageSnapshot({
    required this.filesystem,
    required this.mount,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.usedPercent,
  });

  final String filesystem;
  final String mount;
  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final double usedPercent;
}

/// 端口快照。
final class PortProcessSnapshot {
  const PortProcessSnapshot({
    required this.protocol,
    required this.localAddress,
    required this.port,
    required this.state,
    required this.process,
  });

  final String protocol;
  final String localAddress;
  final int port;
  final String state;
  final String process;
}

/// 进程快照。
final class ApplicationMemorySnapshot {
  const ApplicationMemorySnapshot({
    required this.pid,
    required this.command,
    required this.rssBytes,
    required this.memoryPercent,
    required this.cpuPercent,
  });

  final int pid;
  final String command;
  final int rssBytes;
  final double memoryPercent;
  final double cpuPercent;
}

/// 服务快照。
final class ServiceStatusSnapshot {
  const ServiceStatusSnapshot({
    required this.name,
    required this.displayName,
    required this.status,
    required this.activeState,
    required this.loadState,
  });

  final String name;
  final String displayName;
  final String status;
  final String activeState;
  final String loadState;
}

/// System Admin 读取监控数据的最小 Capability。
abstract interface class SystemAdminMonitoringPort implements Listenable {
  static const maxRetention = Duration(minutes: 10);

  static const intervalOptions = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  static const historyWindowOptions = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 3),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  bool get isRunning;
  bool get isSampling;
  Set<String> get selectedConnectionIds;
  Set<String> get monitoringConnectionIds;
  Duration get interval;
  Duration get historyWindow;
  Duration get effectiveInterval;
  DateTime? get startedAt;
  List<MonitorAlert> get alerts;

  List<PerformanceSample> visibleSamplesFor(String connectionId);
  List<DiskUsageSnapshot> diskUsageFor(String connectionId);
  ServerHealthSnapshot healthFor(String connectionId);

  Future<void> startMonitoring({SshHostKeyConfirmation? onUnknownHostKey});
  void stopMonitoring();
  Future<void> sampleNow({SshHostKeyConfirmation? onUnknownHostKey});
  void setInterval(Duration value);
  void setHistoryWindow(Duration value);
  void toggleSelection(String connectionId);

  Future<List<PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  });
  Future<List<ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  });
  Future<List<ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  });
}
