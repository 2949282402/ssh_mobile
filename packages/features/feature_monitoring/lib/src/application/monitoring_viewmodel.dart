// Monitoring Route 使用的 ViewModel；只持有页面状态，不拥有 App Scope 服务。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../domain/monitoring_models.dart';
import 'monitoring_service.dart';

/// 监控页面的路由级状态协调器。
final class MonitoringViewModel extends ChangeNotifier {
  /// 页面可选的轮询间隔。
  static const List<Duration> intervalOptions =
      MonitoringService.intervalOptions;

  /// 页面可选的历史窗口。
  static const List<Duration> historyWindowOptions =
      MonitoringService.historyWindowOptions;

  /// 创建一个只监听、不拥有监控服务的 ViewModel。
  MonitoringViewModel(this._monitorService) {
    _monitorService.addListener(notifyListeners);
  }

  final MonitoringService _monitorService;
  int _activeTabIndex = 0;
  bool _serversCollapsed = false;
  String? _activeConnectionId;

  @override
  void dispose() {
    _monitorService.removeListener(notifyListeners);
    super.dispose();
  }

  /// 当前监控内容页签。
  int get activeTabIndex => _activeTabIndex;

  /// 是否折叠服务器选择区域。
  bool get serversCollapsed => _serversCollapsed;

  /// 当前详情页连接。
  String? get activeConnectionId => _activeConnectionId;

  /// 是否已有运行中的轮询。
  bool get isRunning => _monitorService.isRunning;

  /// 是否有采样任务正在执行。
  bool get isSampling => _monitorService.isSampling;

  /// 当前被选中的连接。
  Set<String> get selectedConnectionIds =>
      _monitorService.selectedConnectionIds;

  /// 当前参与轮询的连接。
  Set<String> get monitoringConnectionIds =>
      _monitorService.monitoringConnectionIds;

  /// 读取页面历史窗口中的样本。
  List<PerformanceSample> getSamples(String connectionId) =>
      _monitorService.visibleSamplesFor(connectionId);

  /// 读取连接磁盘快照。
  List<DiskUsageSnapshot> getDiskUsage(String connectionId) =>
      _monitorService.diskUsageFor(connectionId);

  /// 读取连接健康状态。
  ServerHealthSnapshot getHealth(String connectionId) =>
      _monitorService.healthFor(connectionId);

  /// 修改当前页签。
  void setTabIndex(int index) {
    if (_activeTabIndex == index) return;
    _activeTabIndex = index;
    notifyListeners();
  }

  /// 修改服务器选择区域折叠状态。
  void setServersCollapsed(bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    _serversCollapsed = collapsed;
    notifyListeners();
  }

  /// 修改当前详情连接。
  void setActiveConnection(String? connectionId) {
    if (_activeConnectionId == connectionId) return;
    _activeConnectionId = connectionId;
    notifyListeners();
  }

  /// 显式启动监控轮询。
  Future<void> startMonitoring({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _monitorService.startMonitoring(onUnknownHostKey: onUnknownHostKey);
  }

  /// 停止轮询并释放当前采样状态。
  void stopMonitoring() => _monitorService.stopMonitoring();

  /// 不等待地触发一次刷新。
  void forceRefresh({ssh_core.SshHostKeyConfirmation? onUnknownHostKey}) {
    unawaited(_monitorService.sampleNow(onUnknownHostKey: onUnknownHostKey));
  }

  /// 等待一次刷新完成。
  Future<void> sampleNow({ssh_core.SshHostKeyConfirmation? onUnknownHostKey}) {
    return _monitorService.sampleNow(onUnknownHostKey: onUnknownHostKey);
  }

  /// 当前轮询间隔。
  Duration get interval => _monitorService.interval;

  /// 当前采样历史窗口。
  Duration get historyWindow => _monitorService.historyWindow;

  /// 考虑失败退避后的实际间隔。
  Duration get effectiveInterval => _monitorService.effectiveInterval;

  /// 当前轮询启动时间。
  DateTime? get startedAt => _monitorService.startedAt;

  /// 当前告警列表。
  List<MonitorAlert> get alerts => _monitorService.alerts;

  /// 修改轮询间隔。
  void setInterval(Duration value) => _monitorService.setInterval(value);

  /// 修改采样历史窗口。
  void setHistoryWindow(Duration value) =>
      _monitorService.setHistoryWindow(value);

  /// 切换连接选择。
  void toggleSelection(String connectionId) =>
      _monitorService.toggleSelection(connectionId);

  /// 读取监听端口。
  Future<List<PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _monitorService.fetchPorts(
      connectionId,
      onUnknownHostKey: onUnknownHostKey,
    );
  }

  /// 读取进程摘要。
  Future<List<ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _monitorService.fetchApplications(
      connectionId,
      onUnknownHostKey: onUnknownHostKey,
    );
  }

  /// 读取服务状态。
  Future<List<ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) {
    return _monitorService.fetchServices(
      connectionId,
      onUnknownHostKey: onUnknownHostKey,
    );
  }

  /// 读取未裁剪的样本，用于工具或导出场景。
  List<PerformanceSample> samplesFor(String connectionId) =>
      _monitorService.samplesFor(connectionId);

  /// 读取磁盘使用快照。
  List<DiskUsageSnapshot> diskUsageFor(String connectionId) =>
      _monitorService.diskUsageFor(connectionId);

  /// 读取健康状态。
  ServerHealthSnapshot healthFor(String connectionId) =>
      _monitorService.healthFor(connectionId);
}
