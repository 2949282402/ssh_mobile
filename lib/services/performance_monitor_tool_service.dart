import 'performance_monitor_service.dart';

abstract interface class PerformanceMonitorToolAdapter {
  Map<String, dynamic> getState();

  Map<String, dynamic> setSelectedServers(List<String> connectionIds);

  Map<String, dynamic> clearSelection();

  Future<Map<String, dynamic>> start();

  Map<String, dynamic> stop();

  Map<String, dynamic> stopForConnection(String connectionId);

  Map<String, dynamic> setInterval(Duration interval);

  Map<String, dynamic> setHistoryWindow(Duration window);

  Map<String, dynamic> getHealth({List<String>? connectionIds});

  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  });

  Map<String, dynamic> getAlerts({int limit = 50});

  Future<Map<String, dynamic>> getPorts(String connectionId);

  Future<Map<String, dynamic>> getApplications(String connectionId);
}

class PerformanceMonitorToolService implements PerformanceMonitorToolAdapter {
  final PerformanceMonitorService service;

  const PerformanceMonitorToolService(this.service);

  @override
  Map<String, dynamic> getState() {
    return {
      'isRunning': service.isRunning,
      'isSampling': service.isSampling,
      'intervalSeconds': service.interval.inSeconds,
      'effectiveIntervalSeconds': service.effectiveInterval.inSeconds,
      'historyWindowSeconds': service.historyWindow.inSeconds,
      'startedAt': service.startedAt?.toIso8601String(),
      'selectedConnectionIds': service.selectedConnectionIds.toList(),
      'monitoringConnectionIds': service.monitoringConnectionIds.toList(),
      'errorsByConnection': service.errorsByConnection,
      'health': {
        for (final entry in service.healthByConnection.entries)
          entry.key: entry.value.toJson(),
      },
      'alerts': service.alerts.map((item) => item.toJson()).toList(),
    };
  }

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) {
    if (service.isRunning) {
      throw StateError(
        'Stop monitoring before changing the selected server set.',
      );
    }
    final current = service.selectedConnectionIds.toList();
    for (final id in current) {
      if (!connectionIds.contains(id)) {
        service.toggleSelection(id);
      }
    }
    for (final id in connectionIds) {
      if (!service.selectedConnectionIds.contains(id)) {
        service.toggleSelection(id);
      }
    }
    return getState();
  }

  @override
  Map<String, dynamic> clearSelection() {
    service.clearSelection();
    return getState();
  }

  @override
  Future<Map<String, dynamic>> start() async {
    await service.startMonitoring();
    return getState();
  }

  @override
  Map<String, dynamic> stop() {
    service.stopMonitoring();
    return getState();
  }

  @override
  Map<String, dynamic> stopForConnection(String connectionId) {
    service.stopForConnection(connectionId);
    return getState();
  }

  @override
  Map<String, dynamic> setInterval(Duration interval) {
    service.setInterval(interval);
    return getState();
  }

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) {
    service.setHistoryWindow(window);
    return getState();
  }

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) {
    final ids = connectionIds == null || connectionIds.isEmpty
        ? service.healthByConnection.keys.toList()
        : connectionIds;
    return {
      'health': {
        for (final id in ids) id: service.healthFor(id).toJson(),
      },
    };
  }

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) {
    final samples = visibleOnly
        ? service.visibleSamplesFor(connectionId)
        : service.samplesFor(connectionId);
    final capped = samples.length <= limit
        ? samples
        : samples.sublist(samples.length - limit);
    return {
      'connectionId': connectionId,
      'visibleOnly': visibleOnly,
      'limit': limit,
      'samples': capped.map(_sampleToJson).toList(),
      'returned': capped.length,
      'truncated': capped.length != samples.length,
    };
  }

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) {
    final alerts = service.alerts.reversed.take(limit).map((item) {
      return item.toJson();
    }).toList(growable: false);
    return {
      'alerts': alerts,
      'returned': alerts.length,
      'limit': limit,
    };
  }

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) async {
    final ports = await service.fetchPorts(connectionId);
    return {
      'connectionId': connectionId,
      'ports': ports.map((item) => item.toJson()).toList(),
    };
  }

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) async {
    final applications = await service.fetchApplications(connectionId);
    return {
      'connectionId': connectionId,
      'applications': applications.map((item) => item.toJson()).toList(),
    };
  }

  Map<String, dynamic> _sampleToJson(PerformanceSample sample) {
    return {
      'connectionId': sample.connectionId,
      'time': sample.time.toIso8601String(),
      'cpuPercent': sample.cpuPercent,
      'memoryPercent': sample.memoryPercent,
      'diskBytesPerSecond': sample.diskBytesPerSecond,
      'networkBytesPerSecond': sample.networkBytesPerSecond,
      'diskUsage': sample.diskUsage.map((item) => item.toJson()).toList(),
    };
  }
}
