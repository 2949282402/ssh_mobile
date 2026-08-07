import 'package:flutter/foundation.dart';

/// 服务器健康等级。
enum ServerHealthLevel { unknown, healthy, warning, critical }

/// 单个连接的健康评分和最近采样摘要。
class ServerHealthSnapshot {
  final String connectionId;
  final ServerHealthLevel level;
  final int score;
  final String summary;
  final List<String> details;
  final DateTime updatedAt;
  final PerformanceSample? latestSample;
  final double maxDiskUsedPercent;

  const ServerHealthSnapshot({
    required this.connectionId,
    required this.level,
    required this.score,
    required this.summary,
    required this.details,
    required this.updatedAt,
    this.latestSample,
    this.maxDiskUsedPercent = 0,
  });

  Map<String, dynamic> toJson() => {
    'connectionId': connectionId,
    'level': level.name,
    'score': score,
    'summary': summary,
    'details': details,
    'updatedAt': updatedAt.toIso8601String(),
    'maxDiskUsedPercent': maxDiskUsedPercent,
    if (latestSample != null)
      'latestSample': {
        'cpuPercent': latestSample!.cpuPercent,
        'memoryPercent': latestSample!.memoryPercent,
        'diskBytesPerSecond': latestSample!.diskBytesPerSecond,
        'networkBytesPerSecond': latestSample!.networkBytesPerSecond,
      },
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ServerHealthSnapshot &&
            other.connectionId == connectionId &&
            other.level == level &&
            other.score == score &&
            other.summary == summary &&
            listEquals(other.details, details) &&
            other.updatedAt == updatedAt &&
            other.latestSample == latestSample &&
            other.maxDiskUsedPercent == maxDiskUsedPercent;
  }

  @override
  int get hashCode => Object.hash(
    connectionId,
    level,
    score,
    summary,
    Object.hashAll(details),
    updatedAt,
    latestSample,
    maxDiskUsedPercent,
  );
}

/// 经过时间去重后的监控告警。
class MonitorAlert {
  final String id;
  final String connectionId;
  final String metric;
  final ServerHealthLevel level;
  final String message;
  final DateTime createdAt;

  const MonitorAlert({
    required this.id,
    required this.connectionId,
    required this.metric,
    required this.level,
    required this.message,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'connectionId': connectionId,
    'metric': metric,
    'level': level.name,
    'message': message,
    'createdAt': createdAt.toIso8601String(),
  };
}

/// 单次服务器性能采样。
class PerformanceSample {
  final String connectionId;
  final DateTime time;
  final double cpuPercent;
  final double memoryPercent;
  final double diskBytesPerSecond;
  final double networkBytesPerSecond;
  final List<DiskUsageSnapshot> diskUsage;

  const PerformanceSample({
    required this.connectionId,
    required this.time,
    required this.cpuPercent,
    required this.memoryPercent,
    required this.diskBytesPerSecond,
    required this.networkBytesPerSecond,
    this.diskUsage = const [],
  });
}

/// Linux 采样解析后的累计计数和磁盘快照。
class RawServerCounters {
  final RawPerformanceCounters counters;
  final List<DiskUsageSnapshot> diskUsage;

  const RawServerCounters({required this.counters, required this.diskUsage});
}

/// Windows PowerShell 状态命令解析后的实时快照。
class WindowsStatusSnapshot {
  final double cpuPercent;
  final double memoryPercent;
  final double diskBytesPerSecond;
  final double networkBytesPerSecond;
  final List<DiskUsageSnapshot> diskUsage;
  final List<PortProcessSnapshot> ports;
  final List<ApplicationMemorySnapshot> applications;
  final List<ServiceStatusSnapshot> services;

  const WindowsStatusSnapshot({
    required this.cpuPercent,
    required this.memoryPercent,
    required this.diskBytesPerSecond,
    required this.networkBytesPerSecond,
    required this.diskUsage,
    required this.ports,
    required this.applications,
    required this.services,
  });
}

/// Linux `/proc` 中的累计 CPU、内存、磁盘和网络计数。
class RawPerformanceCounters {
  final DateTime time;
  final int cpuTotal;
  final int cpuBusy;
  final double memoryPercent;
  final int diskBytes;
  final int networkBytes;

  const RawPerformanceCounters({
    required this.time,
    required this.cpuTotal,
    required this.cpuBusy,
    required this.memoryPercent,
    required this.diskBytes,
    required this.networkBytes,
  });
}

/// 单个真实文件系统的容量使用情况。
class DiskUsageSnapshot {
  final String filesystem;
  final String mount;
  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final double usedPercent;

  const DiskUsageSnapshot({
    required this.filesystem,
    required this.mount,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.usedPercent,
  });

  Map<String, dynamic> toJson() => {
    'filesystem': filesystem,
    'mount': mount,
    'totalBytes': totalBytes,
    'usedBytes': usedBytes,
    'availableBytes': availableBytes,
    'usedPercent': usedPercent,
  };
}

/// 监听端口及其关联进程摘要。
class PortProcessSnapshot {
  final String protocol;
  final String localAddress;
  final int port;
  final String state;
  final String process;

  const PortProcessSnapshot({
    required this.protocol,
    required this.localAddress,
    required this.port,
    required this.state,
    required this.process,
  });

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'localAddress': localAddress,
    'port': port,
    'state': state,
    'process': process,
  };
}

/// 进程 CPU、内存和 RSS 摘要。
class ApplicationMemorySnapshot {
  final int pid;
  final String command;
  final int rssBytes;
  final double memoryPercent;
  final double cpuPercent;

  const ApplicationMemorySnapshot({
    required this.pid,
    required this.command,
    required this.rssBytes,
    required this.memoryPercent,
    required this.cpuPercent,
  });

  Map<String, dynamic> toJson() => {
    'pid': pid,
    'command': command,
    'rssBytes': rssBytes,
    'memoryPercent': memoryPercent,
    'cpuPercent': cpuPercent,
  };
}

/// systemd 或 Windows 服务状态摘要。
class ServiceStatusSnapshot {
  final String name;
  final String displayName;
  final String status;
  final String activeState;
  final String loadState;

  const ServiceStatusSnapshot({
    required this.name,
    required this.displayName,
    required this.status,
    required this.activeState,
    required this.loadState,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'displayName': displayName,
    'status': status,
    'activeState': activeState,
    'loadState': loadState,
  };
}
