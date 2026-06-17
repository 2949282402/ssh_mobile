part of '../system_admin_screen.dart';

class _MonitorConfigSnapshot {
  final bool isRunning;
  final bool isSampling;
  final Duration interval;
  final Duration historyWindow;
  final Duration effectiveInterval;
  final DateTime? startedAt;
  final int selectedCount;
  final int monitoringCount;

  const _MonitorConfigSnapshot({
    required this.isRunning,
    required this.isSampling,
    required this.interval,
    required this.historyWindow,
    required this.effectiveInterval,
    required this.startedAt,
    required this.selectedCount,
    required this.monitoringCount,
  });

  factory _MonitorConfigSnapshot.from(PerformanceMonitorViewModel monitor) {
    return _MonitorConfigSnapshot(
      isRunning: monitor.isRunning,
      isSampling: monitor.isSampling,
      interval: monitor.interval,
      historyWindow: monitor.historyWindow,
      effectiveInterval: monitor.effectiveInterval,
      startedAt: monitor.startedAt,
      selectedCount: monitor.selectedConnectionIds.length,
      monitoringCount: monitor.monitoringConnectionIds.length,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MonitorConfigSnapshot &&
        other.isRunning == isRunning &&
        other.isSampling == isSampling &&
        other.interval == interval &&
        other.historyWindow == historyWindow &&
        other.effectiveInterval == effectiveInterval &&
        other.startedAt == startedAt &&
        other.selectedCount == selectedCount &&
        other.monitoringCount == monitoringCount;
  }

  @override
  int get hashCode => Object.hash(
        isRunning,
        isSampling,
        interval,
        historyWindow,
        effectiveInterval,
        startedAt,
        selectedCount,
        monitoringCount,
      );
}

class _MonitorPerformanceSnapshot {
  final bool isRunning;
  final bool isSampling;
  final Duration historyWindow;
  final int alertCount;
  final String? newestAlertId;
  final List<_MonitorConnectionRenderToken> connections;

  const _MonitorPerformanceSnapshot({
    required this.isRunning,
    required this.isSampling,
    required this.historyWindow,
    required this.alertCount,
    required this.newestAlertId,
    required this.connections,
  });

  factory _MonitorPerformanceSnapshot.from(
    PerformanceMonitorViewModel monitor,
    List<ConnectionConfig> connections,
  ) {
    return _MonitorPerformanceSnapshot(
      isRunning: monitor.isRunning,
      isSampling: monitor.isSampling,
      historyWindow: monitor.historyWindow,
      alertCount: monitor.alerts.length,
      newestAlertId: monitor.alerts.isEmpty ? null : monitor.alerts.first.id,
      connections: [
        for (final connection in connections)
          _MonitorConnectionRenderToken.from(monitor, connection.id),
      ],
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MonitorPerformanceSnapshot &&
        other.isRunning == isRunning &&
        other.isSampling == isSampling &&
        other.historyWindow == historyWindow &&
        other.alertCount == alertCount &&
        other.newestAlertId == newestAlertId &&
        listEquals(other.connections, connections);
  }

  @override
  int get hashCode => Object.hash(
        isRunning,
        isSampling,
        historyWindow,
        alertCount,
        newestAlertId,
        Object.hashAll(connections),
      );
}

class _MonitorConnectionRenderToken {
  final String connectionId;
  final int visibleSampleCount;
  final int latestVisibleSampleMicros;
  final int diskUsageCount;
  final int healthUpdatedAtMicros;
  final int healthScore;
  final ServerHealthLevel healthLevel;

  const _MonitorConnectionRenderToken({
    required this.connectionId,
    required this.visibleSampleCount,
    required this.latestVisibleSampleMicros,
    required this.diskUsageCount,
    required this.healthUpdatedAtMicros,
    required this.healthScore,
    required this.healthLevel,
  });

  factory _MonitorConnectionRenderToken.from(
    PerformanceMonitorViewModel monitor,
    String connectionId,
  ) {
    final visibleSamples = monitor.visibleSamplesFor(connectionId);
    final health = monitor.healthFor(connectionId);
    return _MonitorConnectionRenderToken(
      connectionId: connectionId,
      visibleSampleCount: visibleSamples.length,
      latestVisibleSampleMicros: visibleSamples.isEmpty
          ? 0
          : visibleSamples.last.time.microsecondsSinceEpoch,
      diskUsageCount: monitor.diskUsageFor(connectionId).length,
      healthUpdatedAtMicros: health.updatedAt.microsecondsSinceEpoch,
      healthScore: health.score,
      healthLevel: health.level,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MonitorConnectionRenderToken &&
        other.connectionId == connectionId &&
        other.visibleSampleCount == visibleSampleCount &&
        other.latestVisibleSampleMicros == latestVisibleSampleMicros &&
        other.diskUsageCount == diskUsageCount &&
        other.healthUpdatedAtMicros == healthUpdatedAtMicros &&
        other.healthScore == healthScore &&
        other.healthLevel == healthLevel;
  }

  @override
  int get hashCode => Object.hash(
        connectionId,
        visibleSampleCount,
        latestVisibleSampleMicros,
        diskUsageCount,
        healthUpdatedAtMicros,
        healthScore,
        healthLevel,
      );
}
