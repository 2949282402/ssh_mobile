import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../../services/performance_monitor_service.dart';
import '../../../../services/server_status_probe.dart';

class PerformanceMonitorViewModel extends ChangeNotifier {
  final PerformanceMonitorService _monitorService;

  int _activeTabIndex = 0;
  bool _serversCollapsed = false;
  String? _activeConnectionId;

  PerformanceMonitorViewModel({
    required PerformanceMonitorService monitorService,
  }) : _monitorService = monitorService {
    _monitorService.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _monitorService.removeListener(notifyListeners);
    super.dispose();
  }

  int get activeTabIndex => _activeTabIndex;
  bool get serversCollapsed => _serversCollapsed;
  String? get activeConnectionId => _activeConnectionId;

  bool get isRunning => _monitorService.isRunning;
  bool get isSampling => _monitorService.isSampling;
  Set<String> get selectedConnectionIds => _monitorService.selectedConnectionIds;
  Set<String> get monitoringConnectionIds => _monitorService.monitoringConnectionIds;

  List<PerformanceSample> getSamples(String connectionId) {
    return _monitorService.visibleSamplesFor(connectionId);
  }

  List<DiskUsageSnapshot> getDiskUsage(String connectionId) {
    return _monitorService.diskUsageFor(connectionId);
  }

  ServerHealthSnapshot getHealth(String connectionId) {
    return _monitorService.healthFor(connectionId);
  }

  void setTabIndex(int index) {
    if (_activeTabIndex == index) return;
    _activeTabIndex = index;
    notifyListeners();
  }

  void setServersCollapsed(bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    _serversCollapsed = collapsed;
    notifyListeners();
  }

  void setActiveConnection(String? connectionId) {
    if (_activeConnectionId == connectionId) return;
    _activeConnectionId = connectionId;
    notifyListeners();
  }

  Future<void> startMonitoring() async {
    await _monitorService.startMonitoring();
  }

  void stopMonitoring() {
    _monitorService.stopMonitoring();
  }

  void forceRefresh() {
    unawaited(_monitorService.sampleNow());
  }
}
