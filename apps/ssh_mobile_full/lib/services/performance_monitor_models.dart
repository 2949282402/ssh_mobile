part of 'performance_monitor_service.dart';

enum ServerHealthLevel { unknown, healthy, warning, critical }

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
