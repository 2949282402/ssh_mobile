// ignore_for_file: unused_element, unused_element_parameter

import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/performance_monitor_service.dart';
import '../services/server_status_probe.dart';
import '../services/storage_service.dart';
import '../utils/responsive.dart';
import '../widgets/overflow_scroll_text.dart';

part 'performance_monitor/monitor_strings.dart';
part 'performance_monitor/monitor_models.dart';
part 'performance_monitor/server_navigation.dart';
part 'performance_monitor/performance_charts.dart';
part 'performance_monitor/monitor_config.dart';
part 'performance_monitor/health_disk_views.dart';
part 'performance_monitor/details_views.dart';

class PerformanceMonitorScreen extends StatefulWidget {
  const PerformanceMonitorScreen({super.key});

  @override
  State<PerformanceMonitorScreen> createState() =>
      _PerformanceMonitorScreenState();
}

class _PerformanceMonitorScreenState extends State<PerformanceMonitorScreen> {
  static const _serversCollapsedStorageKey = 'performance_servers_collapsed';

  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;
  int _tabIndex = 0;
  int _selectionVersion = 0;
  String? _portConnectionId;
  String? _appConnectionId;
  String? _serviceConnectionId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredServersCollapsed) return;
    _restoredServersCollapsed = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: _serversCollapsedStorageKey,
    );
    if (stored is bool) _serversCollapsed = stored;
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final storageReady = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (storage) => storage.connections,
    );
    final monitor = context.read<PerformanceMonitorService>();
    final monitorShell =
        context.select<PerformanceMonitorService, _MonitorShellSnapshot>(
      (monitor) => _MonitorShellSnapshot.from(monitor),
    );
    final desktop = isDesktopLayout(context);
    final monitoringConnections = _connectionsByIds(
      connections,
      monitorShell.monitoringConnectionIds,
    );
    final selectedConnections = _connectionsByIds(
      connections,
      monitorShell.selectedConnectionIds,
    );
    final portConnections = _portConnectionId == null
        ? const <ConnectionConfig>[]
        : _connectionsByIds(connections, {_portConnectionId!});
    final appConnections = _appConnectionId == null
        ? const <ConnectionConfig>[]
        : _connectionsByIds(connections, {_appConnectionId!});
    final serviceConnections = _serviceConnectionId == null
        ? const <ConnectionConfig>[]
        : _connectionsByIds(connections, {_serviceConnectionId!});

    final tabSelectedIds = _selectedIdsForTab(monitorShell);
    final tabSelectedConnections =
        _connectionsByIds(connections, tabSelectedIds);
    final railConnections = _tabIndex == 0 && monitorShell.isRunning
        ? monitoringConnections
        : tabSelectedConnections;
    final serversCollapsed = _serversCollapsed && connections.isNotEmpty;

    if (!storageReady) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Column(
      children: [
        _MonitorTopTabs(
          selectedIndex: _tabIndex,
          strings: strings,
          onChanged: (index) => _setMonitorTab(index),
        ),
        Expanded(
          child: desktop
              ? Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: serversCollapsed ? 64 : 320,
                      child: serversCollapsed
                          ? Selector<PerformanceMonitorService, bool>(
                              selector: (_, monitor) => monitor.isSampling,
                              builder: (context, sampling, _) =>
                                  _CollapsedDesktopMonitorRail(
                                connections: railConnections,
                                sampling: sampling && _tabIndex == 0,
                                strings: strings,
                                onExpand: _expandServers,
                              ),
                            )
                          : _MonitorServerPane(
                              connections: connections,
                              strings: strings,
                              selectedConnectionIds: tabSelectedIds,
                              disabled:
                                  _tabIndex == 0 && monitorShell.isRunning,
                              onConnectionTap: (id) =>
                                  _handleServerSelection(context, monitor, id),
                              onDisabledTap: () =>
                                  _showSelectionFrozenHint(context, strings),
                              onCollapse: _collapseServers,
                            ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(
                      child: _MonitorContent(
                        strings: strings,
                        monitor: monitor,
                        tabIndex: _tabIndex,
                        selectionVersion: _selectionVersion,
                        selectedConnections: selectedConnections,
                        monitoringConnections: monitoringConnections,
                        portConnections: portConnections,
                        appConnections: appConnections,
                        serviceConnections: serviceConnections,
                        onStartMonitoring: () async {
                          await monitor.startMonitoring();
                          if (mounted) _collapseServers();
                        },
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: serversCollapsed
                          ? Selector<PerformanceMonitorService, bool>(
                              key: const ValueKey('monitor-server-collapsed'),
                              selector: (_, monitor) => monitor.isSampling,
                              builder: (context, sampling, _) =>
                                  _CollapsedMobileMonitorBar(
                                connections: railConnections,
                                sampling: sampling && _tabIndex == 0,
                                strings: strings,
                                onExpand: _expandServers,
                              ),
                            )
                          : _MobileMonitorServerStrip(
                              key: const ValueKey('monitor-server-expanded'),
                              connections: connections,
                              strings: strings,
                              selectedConnectionIds: tabSelectedIds,
                              disabled:
                                  _tabIndex == 0 && monitorShell.isRunning,
                              onConnectionTap: (id) =>
                                  _handleServerSelection(context, monitor, id),
                              onDisabledTap: () =>
                                  _showSelectionFrozenHint(context, strings),
                              onCollapse: _collapseServers,
                            ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(
                      child: _MonitorContent(
                        strings: strings,
                        monitor: monitor,
                        tabIndex: _tabIndex,
                        selectionVersion: _selectionVersion,
                        selectedConnections: selectedConnections,
                        monitoringConnections: monitoringConnections,
                        portConnections: portConnections,
                        appConnections: appConnections,
                        serviceConnections: serviceConnections,
                        onStartMonitoring: () async {
                          await monitor.startMonitoring();
                          if (mounted) _collapseServers();
                        },
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  List<ConnectionConfig> _connectionsByIds(
    List<ConnectionConfig> connections,
    Set<String> ids,
  ) {
    return [
      for (final connection in connections)
        if (ids.contains(connection.id)) connection,
    ];
  }

  void _collapseServers() => _setServersCollapsed(true);

  void _expandServers() => _setServersCollapsed(false);

  void _setServersCollapsed(bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    setState(() => _serversCollapsed = collapsed);
    PageStorage.maybeOf(context)?.writeState(
      context,
      collapsed,
      identifier: _serversCollapsedStorageKey,
    );
  }

  Set<String> _selectedIdsForTab(_MonitorShellSnapshot monitorShell) {
    switch (_tabIndex) {
      case 1:
        return _portConnectionId == null ? const {} : {_portConnectionId!};
      case 2:
        return _appConnectionId == null ? const {} : {_appConnectionId!};
      case 3:
        return _serviceConnectionId == null
            ? const {}
            : {_serviceConnectionId!};
      case 0:
      default:
        return monitorShell.selectedConnectionIds;
    }
  }

  void _setMonitorTab(int index) {
    setState(() {
      _tabIndex = index;
      _selectionVersion++;
    });
  }

  void _handleServerSelection(
    BuildContext context,
    PerformanceMonitorService monitor,
    String connectionId,
  ) {
    if (_tabIndex == 0) {
      if (monitor.isRunning) {
        _showSelectionFrozenHint(
            context, AppStrings(context.read<AppSettings>().language));
        return;
      }
      monitor.toggleSelection(connectionId);
      return;
    }
    setState(() {
      if (_tabIndex == 1) {
        _portConnectionId = connectionId;
      } else if (_tabIndex == 2) {
        _appConnectionId = connectionId;
      } else {
        _serviceConnectionId = connectionId;
      }
      _selectionVersion++;
    });
  }

  void _showSelectionFrozenHint(BuildContext context, AppStrings strings) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _monitorText(
            strings,
            'Stop monitoring before changing server selection.',
            '请先结束监控后再重新选择服务器。',
          ),
        ),
      ),
    );
  }
}

class _MonitorContent extends StatefulWidget {
  final AppStrings strings;
  final PerformanceMonitorService monitor;
  final int tabIndex;
  final int selectionVersion;
  final List<ConnectionConfig> selectedConnections;
  final List<ConnectionConfig> monitoringConnections;
  final List<ConnectionConfig> portConnections;
  final List<ConnectionConfig> appConnections;
  final List<ConnectionConfig> serviceConnections;
  final Future<void> Function() onStartMonitoring;

  const _MonitorContent({
    required this.strings,
    required this.monitor,
    required this.tabIndex,
    required this.selectionVersion,
    required this.selectedConnections,
    required this.monitoringConnections,
    required this.portConnections,
    required this.appConnections,
    required this.serviceConnections,
    required this.onStartMonitoring,
  });

  @override
  State<_MonitorContent> createState() => _MonitorContentState();
}

class _MonitorContentState extends State<_MonitorContent> {
  bool _configExpanded = true;
  bool _wasRunning = false;
  bool _diskExpanded = true;
  int _serversPerChart = 1;
  Future<Map<String, List<PortProcessSnapshot>>>? _portsFuture;
  Future<Map<String, List<ApplicationMemorySnapshot>>>? _appsFuture;
  Future<Map<String, List<ServiceStatusSnapshot>>>? _servicesFuture;
  String? _portsSelectionKey;
  String? _appsSelectionKey;
  String? _servicesSelectionKey;
  String? _chartItemsCacheKey;
  List<_MetricChartItem> _chartItemsCache = const [];
  final Set<String> _collapsedChartKeys = {};

  AppStrings get strings => widget.strings;
  PerformanceMonitorService get monitor => widget.monitor;
  List<ConnectionConfig> get activeConnections {
    return monitor.isRunning
        ? widget.monitoringConnections
        : widget.selectedConnections;
  }

  @override
  void initState() {
    super.initState();
    _refreshSnapshotFutureForActiveTab();
  }

  @override
  void didUpdateWidget(covariant _MonitorContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tabIndex != oldWidget.tabIndex ||
        widget.selectionVersion != oldWidget.selectionVersion) {
      _refreshSnapshotFutureForActiveTab();
    }
  }

  void _refreshSnapshotFutureForActiveTab() {
    if (widget.tabIndex == 1) {
      _refreshPortsFuture();
    } else if (widget.tabIndex == 2) {
      _refreshApplicationsFuture();
    } else if (widget.tabIndex == 3) {
      _refreshServicesFuture();
    }
  }

  void _refreshPortsFuture({bool force = false}) {
    final key = _connectionsCacheKey(widget.portConnections);
    if (key == null) {
      _portsSelectionKey = null;
      _portsFuture = null;
      return;
    }
    if (force || _portsFuture == null || _portsSelectionKey != key) {
      _portsSelectionKey = key;
      _portsFuture = _loadPorts();
    }
  }

  void _refreshApplicationsFuture({bool force = false}) {
    final key = _connectionsCacheKey(widget.appConnections);
    if (key == null) {
      _appsSelectionKey = null;
      _appsFuture = null;
      return;
    }
    if (force || _appsFuture == null || _appsSelectionKey != key) {
      _appsSelectionKey = key;
      _appsFuture = _loadApplications();
    }
  }

  void _refreshServicesFuture({bool force = false}) {
    final key = _connectionsCacheKey(widget.serviceConnections);
    if (key == null) {
      _servicesSelectionKey = null;
      _servicesFuture = null;
      return;
    }
    if (force || _servicesFuture == null || _servicesSelectionKey != key) {
      _servicesSelectionKey = key;
      _servicesFuture = _loadServices();
    }
  }

  String? _connectionsCacheKey(List<ConnectionConfig> connections) {
    if (connections.isEmpty) return null;
    return connections.map((connection) => connection.id).join('|');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.tabIndex == 0)
          Selector<PerformanceMonitorService, _MonitorConfigSnapshot>(
            selector: (_, monitor) => _MonitorConfigSnapshot.from(monitor),
            builder: (context, snapshot, _) {
              if (snapshot.isRunning && !_wasRunning) {
                _configExpanded = false;
              }
              _wasRunning = snapshot.isRunning;
              return _MonitorConfigPanelV2(
                strings: strings,
                monitor: widget.monitor,
                serversPerChart: _serversPerChart,
                onStartMonitoring: widget.onStartMonitoring,
                expanded: _configExpanded,
                onToggle: () =>
                    setState(() => _configExpanded = !_configExpanded),
                onServersPerChartChanged: (value) {
                  setState(() => _serversPerChart = value);
                },
                onCustomInterval: () => _showCustomDuration(
                  title: _monitorText(strings, 'Interval', '刷新间隔'),
                  initial: widget.monitor.interval,
                  onChanged: widget.monitor.setInterval,
                ),
                onCustomWindow: () => _showCustomDuration(
                  title: _monitorText(strings, 'Range', '时间范围'),
                  initial: widget.monitor.historyWindow,
                  max: PerformanceMonitorService.maxRetention,
                  onChanged: widget.monitor.setHistoryWindow,
                ),
              );
            },
          ),
        Expanded(
          child: _buildActiveTab(context),
        ),
      ],
    );
  }

  Widget _buildActiveTab(BuildContext context) {
    return IndexedStack(
      index: widget.tabIndex,
      children: [
        // Tab 0: Performance
        Selector<PerformanceMonitorService, _MonitorPerformanceSnapshot>(
          selector: (_, monitor) => _MonitorPerformanceSnapshot.from(
            monitor,
            widget.monitoringConnections,
          ),
          builder: (context, _, __) => _buildPerformanceTab(context),
        ),
        // Tab 1: Ports
        _ServerSnapshotTab<PortProcessSnapshot>(
          strings: strings,
          connections: widget.portConnections,
          emptyText:
              _monitorText(strings, 'No listening ports found', '未发现监听端口'),
          future: _portsFuture,
          onRefresh: () => setState(() => _refreshPortsFuture(force: true)),
          itemBuilder: _buildPortItem,
        ),
        // Tab 2: Applications
        _ServerSnapshotTab<ApplicationMemorySnapshot>(
          strings: strings,
          connections: widget.appConnections,
          emptyText:
              _monitorText(strings, 'No application data found', '未发现应用数据'),
          future: _appsFuture,
          onRefresh: () =>
              setState(() => _refreshApplicationsFuture(force: true)),
          itemBuilder: _buildApplicationItem,
        ),
        // Tab 3: Services
        _ServerSnapshotTab<ServiceStatusSnapshot>(
          strings: strings,
          connections: widget.serviceConnections,
          emptyText:
              _monitorText(strings, 'No running services found', '未发现运行中的服务'),
          future: _servicesFuture,
          onRefresh: () => setState(() => _refreshServicesFuture(force: true)),
          itemBuilder: _buildServiceItem,
        ),
      ],
    );
  }

  Widget _buildPerformanceTab(BuildContext context) {
    final chartConnections = activeConnections;
    final samplesByConnection = {
      for (final connection in widget.monitoringConnections)
        connection.id: monitor.visibleSamplesFor(connection.id),
    };
    final hasSamples = samplesByConnection.values.any((samples) {
      return samples.isNotEmpty;
    });
    if (!monitor.isRunning) {
      return _MonitorResponsiveEmptyState(
        strings: strings,
        message: widget.selectedConnections.isEmpty
            ? null
            : _monitorText(
                strings,
                'Stop monitoring before changing server selection.',
                '停止监控后可修改服务器选择。'),
      );
    }
    if (!hasSamples) {
      return Center(
        child: Text(_monitorText(strings, 'Waiting for samples', '等待采样数据')),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 860;
        final chartItems = _metricChartItems(chartConnections);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          itemCount: chartItems.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _HealthAlertPanel(
                    strings: strings,
                    connections: chartConnections,
                    monitor: monitor,
                  ),
                ),
              );
            }
            if (index == 1) {
              return RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DiskUsagePanel(
                    strings: strings,
                    connections: chartConnections,
                    monitor: monitor,
                    expanded: _diskExpanded,
                    onToggle: () =>
                        setState(() => _diskExpanded = !_diskExpanded),
                  ),
                ),
              );
            }
            final item = chartItems[index - 2];
            return RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _MetricChart(
                  title: item.title,
                  unit: item.spec.unit,
                  connections: item.connections,
                  samplesByConnection: samplesByConnection,
                  chartHeight: twoColumns ? 178 : 218,
                  maxY: item.spec.maxY,
                  valueFor: item.spec.valueFor,
                  latestTextFor: item.spec.latestTextFor,
                  expanded: !_collapsedChartKeys.contains(item.key),
                  onToggle: () {
                    setState(() {
                      if (!_collapsedChartKeys.remove(item.key)) {
                        _collapsedChartKeys.add(item.key);
                      }
                    });
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<_MetricChartItem> _metricChartItems(
    List<ConnectionConfig> chartConnections,
  ) {
    final cacheKey = [
      strings.language.name,
      _serversPerChart,
      for (final connection in chartConnections) connection.id,
    ].join('|');
    if (_chartItemsCacheKey == cacheKey) {
      return _chartItemsCache;
    }
    final specs = _metricSpecs();
    final items = <_MetricChartItem>[];
    final groupSize = _serversPerChart.clamp(1, 99);
    for (final spec in specs) {
      for (var start = 0; start < chartConnections.length; start += groupSize) {
        final end = min(start + groupSize, chartConnections.length);
        final group = chartConnections.sublist(start, end);
        items.add(
          _MetricChartItem(
            key: '${spec.key}-$start',
            title: group.length == chartConnections.length
                ? spec.title
                : '${spec.title} ${start + 1}-${start + group.length}',
            spec: spec,
            connections: group,
          ),
        );
      }
    }
    _chartItemsCacheKey = cacheKey;
    _chartItemsCache = List.unmodifiable(items);
    return _chartItemsCache;
  }

  List<_MetricSpec> _metricSpecs() {
    return [
      _MetricSpec(
        key: 'cpu',
        title: 'CPU',
        unit: '%',
        maxY: 100,
        valueFor: (sample) => sample.cpuPercent,
        latestTextFor: (sample) => '${sample.cpuPercent.toStringAsFixed(1)}%',
      ),
      _MetricSpec(
        key: 'memory',
        title: _monitorText(strings, 'Memory', '内存'),
        unit: '%',
        maxY: 100,
        valueFor: (sample) => sample.memoryPercent,
        latestTextFor: (sample) =>
            '${sample.memoryPercent.toStringAsFixed(1)}%',
      ),
      _MetricSpec(
        key: 'disk',
        title: _monitorText(strings, 'Disk IO', '磁盘 IO'),
        unit: 'MB/s',
        valueFor: (sample) => sample.diskBytesPerSecond / 1024 / 1024,
        latestTextFor: (sample) =>
            '${_formatRate(sample.diskBytesPerSecond)}/s',
      ),
      _MetricSpec(
        key: 'network',
        title: _monitorText(strings, 'Network', '网络'),
        unit: 'MB/s',
        valueFor: (sample) => sample.networkBytesPerSecond / 1024 / 1024,
        latestTextFor: (sample) =>
            '${_formatRate(sample.networkBytesPerSecond)}/s',
      ),
    ];
  }

  Future<Map<String, List<PortProcessSnapshot>>> _loadPorts() async {
    final result = <String, List<PortProcessSnapshot>>{};
    for (final connection in widget.portConnections) {
      result[connection.id] = await monitor.fetchPorts(connection.id);
    }
    return result;
  }

  Future<Map<String, List<ApplicationMemorySnapshot>>>
      _loadApplications() async {
    final result = <String, List<ApplicationMemorySnapshot>>{};
    for (final connection in widget.appConnections) {
      result[connection.id] = await monitor.fetchApplications(connection.id);
    }
    return result;
  }

  Future<Map<String, List<ServiceStatusSnapshot>>> _loadServices() async {
    final result = <String, List<ServiceStatusSnapshot>>{};
    for (final connection in widget.serviceConnections) {
      result[connection.id] = await monitor.fetchServices(connection.id);
    }
    return result;
  }

  Widget _buildPortItem(BuildContext context, PortProcessSnapshot port) {
    return _PortProcessTile(
      strings: strings,
      port: port,
    );
  }

  Widget _buildApplicationItem(
    BuildContext context,
    ApplicationMemorySnapshot app,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.apps_rounded),
      title: OverflowScrollText(
        app.command,
        selectable: false,
        maxLines: 1,
      ),
      subtitle: Text(
        'PID ${app.pid}  CPU ${app.cpuPercent.toStringAsFixed(1)}%',
        style: TextStyle(color: colorScheme.onSurfaceVariant),
      ),
      trailing: Text(
        _formatBytes(app.rssBytes),
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }

  Widget _buildServiceItem(
      BuildContext context, ServiceStatusSnapshot service) {
    return _ServiceStatusTile(
      strings: strings,
      service: service,
    );
  }

  Future<void> _showCustomDuration({
    required String title,
    required Duration initial,
    required ValueChanged<Duration> onChanged,
    Duration? max,
  }) async {
    final controller = TextEditingController(text: '${initial.inSeconds}');
    var unitSeconds = true;
    final duration = await showDialog<Duration>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text('${_monitorText(strings, 'Custom', '自定义')} $title'),
            content: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: title),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<bool>(
                  value: unitSeconds,
                  items: [
                    DropdownMenuItem(
                      value: true,
                      child: Text(_monitorText(strings, 'Seconds', '秒')),
                    ),
                    DropdownMenuItem(
                      value: false,
                      child: Text(_monitorText(strings, 'Minutes', '分钟')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => unitSeconds = value);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: () {
                  final value = int.tryParse(controller.text.trim());
                  if (value == null || value <= 0) return;
                  final next = unitSeconds
                      ? Duration(seconds: value)
                      : Duration(minutes: value);
                  Navigator.pop(ctx, max != null && next > max ? max : next);
                },
                child: Text(strings.save),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (duration != null) onChanged(duration);
  }

  String _formatRate(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

String _serverSummary(AppStrings strings, List<ConnectionConfig> connections) {
  if (connections.isEmpty) {
    return _monitorText(strings, 'Monitor servers', '监控服务器');
  }
  if (connections.length == 1) {
    final connection = connections.first;
    return '${connection.name}  ${connection.username}@${connection.host}';
  }
  return _monitorText(
    strings,
    '${connections.length} selected',
    '已选择 ${connections.length} 台',
  );
}

String _monitorText(AppStrings strings, String en, String zh) {
  return strings.language == AppLanguage.en ? en : zh;
}

String _durationLabel(Duration duration) {
  if (duration.inMinutes >= 1 && duration.inSeconds % 60 == 0) {
    return '${duration.inMinutes}m';
  }
  return '${duration.inSeconds}s';
}

String _runDurationLabel(DateTime? startedAt) {
  if (startedAt == null) return '0s';
  final duration = DateTime.now().difference(startedAt);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

Color _healthColor(BuildContext context, ServerHealthLevel level) {
  final colorScheme = Theme.of(context).colorScheme;
  return switch (level) {
    ServerHealthLevel.healthy => colorScheme.secondary,
    ServerHealthLevel.warning => Colors.orangeAccent.shade700,
    ServerHealthLevel.critical => colorScheme.error,
    ServerHealthLevel.unknown => colorScheme.onSurfaceVariant,
  };
}

IconData _healthIcon(ServerHealthLevel level) {
  return switch (level) {
    ServerHealthLevel.healthy => Icons.verified_rounded,
    ServerHealthLevel.warning => Icons.warning_amber_rounded,
    ServerHealthLevel.critical => Icons.error_rounded,
    ServerHealthLevel.unknown => Icons.help_outline_rounded,
  };
}

String _healthLabel(AppStrings strings, ServerHealthLevel level) {
  final en = strings.language == AppLanguage.en;
  return switch (level) {
    ServerHealthLevel.healthy => en ? 'Healthy' : '正常',
    ServerHealthLevel.warning => en ? 'Warning' : '警告',
    ServerHealthLevel.critical => en ? 'Critical' : '危险',
    ServerHealthLevel.unknown => en ? 'No samples' : '暂无采样',
  };
}

Color _monitorSeriesColor(int index) {
  const palette = [
    Colors.blue,
    Colors.teal,
    Colors.deepOrange,
    Colors.indigo,
    Colors.pink,
    Colors.green,
    Colors.cyan,
    Colors.brown,
  ];
  return palette[index % palette.length];
}
