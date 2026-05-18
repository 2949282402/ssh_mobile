// ignore_for_file: unused_element, unused_element_parameter

import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/performance_monitor_service.dart';
import '../services/server_status_probe.dart';
import '../services/storage_service.dart';
import '../utils/responsive.dart';

extension _PerformanceStrings on AppStrings {
  bool get _isEn => language == AppLanguage.en;

  String get monitorServers => _isEn ? 'Monitor servers' : '监控服务器';
  String get selectMonitorServer =>
      _isEn ? 'Select servers to monitor' : '选择要监控的服务器';
  String get selectMonitorServerHint => _isEn
      ? 'Select one or more servers, then start monitoring. Sampling stays silent until started.'
      : '可多选服务器，点击开始监控后才采样；未开始前保持静默。';
  String selectedMonitorServers(int count) =>
      _isEn ? '$count selected' : '已选择 $count 台';
  String monitoringServers(int count) => _isEn
      ? 'Monitoring $count server${count == 1 ? '' : 's'}'
      : '正在监控 $count 台服务器';
  String get startMonitoring => _isEn ? 'Start' : '开始监控';
  String get stopMonitoring => _isEn ? 'Stop' : '停止监控';
  String get changeSelectionHint => _isEn
      ? 'Stop monitoring before changing server selection.'
      : '停止监控后可修改服务器选择。';
  String get sampleInterval => _isEn ? 'Interval' : '刷新间隔';
  String get historyWindow => _isEn ? 'Range' : '时间范围';
  String get sampling => _isEn ? 'Sampling...' : '正在采样...';
  String get noSamplesYet => _isEn ? 'Waiting for samples' : '等待采样数据';
  String get cpu => 'CPU';
  String get memory => _isEn ? 'Memory' : '内存';
  String get diskIo => _isEn ? 'Disk IO' : '磁盘 IO';
  String get network => _isEn ? 'Network' : '网络';
}

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
    final strings = AppStrings(context.watch<AppSettings>().language);
    final storageReady = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (storage) => storage.connections,
    );
    final monitor = context.watch<PerformanceMonitorService>();
    final desktop = isDesktopLayout(context);
    final monitoringConnections = _connectionsByIds(
      connections,
      monitor.monitoringConnectionIds,
    );
    final tabSelectedIds = _selectedIdsForTab(monitor);
    final tabSelectedConnections =
        _connectionsByIds(connections, tabSelectedIds);
    final railConnections = _tabIndex == 0 && monitor.isRunning
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
                          ? _CollapsedDesktopMonitorRail(
                              connections: railConnections,
                              sampling: monitor.isSampling && _tabIndex == 0,
                              strings: strings,
                              onExpand: _expandServers,
                            )
                          : _MonitorServerPane(
                              connections: connections,
                              strings: strings,
                              selectedConnectionIds: tabSelectedIds,
                              samplingConnectionIds:
                                  monitor.monitoringConnectionIds,
                              sampling: monitor.isSampling && _tabIndex == 0,
                              disabled: _tabIndex == 0 && monitor.isRunning,
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
                        selectedConnections: tabSelectedConnections,
                        monitoringConnections: monitoringConnections,
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
                          ? _CollapsedMobileMonitorBar(
                              key: const ValueKey('monitor-server-collapsed'),
                              connections: railConnections,
                              sampling: monitor.isSampling && _tabIndex == 0,
                              strings: strings,
                              onExpand: _expandServers,
                            )
                          : _MobileMonitorServerStrip(
                              key: const ValueKey('monitor-server-expanded'),
                              connections: connections,
                              strings: strings,
                              selectedConnectionIds: tabSelectedIds,
                              samplingConnectionIds:
                                  monitor.monitoringConnectionIds,
                              sampling: monitor.isSampling && _tabIndex == 0,
                              disabled: _tabIndex == 0 && monitor.isRunning,
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
                        selectedConnections: tabSelectedConnections,
                        monitoringConnections: monitoringConnections,
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

  Set<String> _selectedIdsForTab(PerformanceMonitorService monitor) {
    switch (_tabIndex) {
      case 1:
        return _portConnectionId == null ? const {} : {_portConnectionId!};
      case 2:
        return _appConnectionId == null ? const {} : {_appConnectionId!};
      case 0:
      default:
        return monitor.selectedConnectionIds;
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
      } else {
        _appConnectionId = connectionId;
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

class _MonitorServerPane extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final Set<String> selectedConnectionIds;
  final Set<String> samplingConnectionIds;
  final bool sampling;
  final bool disabled;
  final ValueChanged<String> onConnectionTap;
  final VoidCallback onDisabledTap;
  final VoidCallback onCollapse;

  const _MonitorServerPane({
    required this.connections,
    required this.strings,
    required this.selectedConnectionIds,
    required this.samplingConnectionIds,
    required this.sampling,
    required this.disabled,
    required this.onConnectionTap,
    required this.onDisabledTap,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (connections.isEmpty) {
      return Material(
        color: colorScheme.surface,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _header(colorScheme),
            _MonitorResponsiveEmptyState(strings: strings),
          ],
        ),
      );
    }
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          _header(colorScheme),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              itemCount: connections.length,
              itemBuilder: (context, index) {
                final connection = connections[index];
                return Container(
                  key: ValueKey(connection.id),
                  margin: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.drag_handle,
                            size: 20,
                            color: colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                      Expanded(
                        child: _MonitorServerTile(
                          connection: connection,
                          selected:
                              selectedConnectionIds.contains(connection.id),
                          sampling: samplingConnectionIds
                                  .contains(connection.id) &&
                              sampling,
                          disabled: disabled,
                          onTap: () => onConnectionTap(connection.id),
                          onDisabledTap: onDisabledTap,
                        ),
                      ),
                    ],
                  ),
                );
              },
              onReorder: (oldIndex, newIndex) {
                context
                    .read<StorageService>()
                    .reorderConnections(oldIndex, newIndex);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _monitorText(strings, 'Monitor servers', '监控服务器'),
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            tooltip: strings.collapseServerList,
            icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
            onPressed: connections.isEmpty ? null : onCollapse,
          ),
        ],
      ),
    );
  }
}

class _MobileMonitorServerStrip extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final Set<String> selectedConnectionIds;
  final Set<String> samplingConnectionIds;
  final bool sampling;
  final bool disabled;
  final ValueChanged<String> onConnectionTap;
  final VoidCallback onDisabledTap;
  final VoidCallback onCollapse;

  const _MobileMonitorServerStrip({
    super.key,
    required this.connections,
    required this.strings,
    required this.selectedConnectionIds,
    required this.samplingConnectionIds,
    required this.sampling,
    required this.disabled,
    required this.onConnectionTap,
    required this.onDisabledTap,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final textScale =
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8).toDouble();
    final stripHeight = 72.0 + (textScale - 1.0) * 18.0;
    if (connections.isEmpty) {
      return SizedBox(
        height: stripHeight,
        child: Center(child: Text(strings.noConnections)),
      );
    }

    return SizedBox(
      height: stripHeight,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: connections.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _MobileMonitorCollapseButton(
              strings: strings,
              onPressed: onCollapse,
            );
          }
          final connection = connections[index - 1];
          return SizedBox(
            width: 210,
            child: _MonitorServerTile(
              connection: connection,
              selected: selectedConnectionIds.contains(connection.id),
              sampling:
                  samplingConnectionIds.contains(connection.id) && sampling,
              disabled: disabled,
              compact: true,
              onTap: () => onConnectionTap(connection.id),
              onDisabledTap: onDisabledTap,
            ),
          );
        },
      ),
    );
  }
}

class _MobileMonitorCollapseButton extends StatelessWidget {
  final AppStrings strings;
  final VoidCallback onPressed;

  const _MobileMonitorCollapseButton({
    required this.strings,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 48,
      child: Material(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: strings.collapseServerList,
          icon: const Icon(Icons.keyboard_double_arrow_up_rounded),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class _CollapsedMobileMonitorBar extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final bool sampling;
  final AppStrings strings;
  final VoidCallback onExpand;

  const _CollapsedMobileMonitorBar({
    super.key,
    required this.connections,
    required this.sampling,
    required this.strings,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: strings.expandServerList,
                  icon: const Icon(Icons.keyboard_double_arrow_down_rounded),
                  onPressed: onExpand,
                ),
                _MonitorStatusIcon(sampling: sampling, compact: true),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _serverSummary(strings, connections),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedDesktopMonitorRail extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final bool sampling;
  final AppStrings strings;
  final VoidCallback onExpand;

  const _CollapsedDesktopMonitorRail({
    required this.connections,
    required this.sampling,
    required this.strings,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 8),
          IconButton(
            tooltip: strings.expandServerList,
            icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
            onPressed: onExpand,
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: _serverSummary(strings, connections),
            child: _MonitorStatusIcon(
              sampling: sampling,
              selected: connections.isNotEmpty,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonitorServerTile extends StatelessWidget {
  final ConnectionConfig connection;
  final bool selected;
  final bool sampling;
  final bool disabled;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback? onDisabledTap;

  const _MonitorServerTile({
    required this.connection,
    required this.selected,
    required this.sampling,
    required this.onTap,
    this.onDisabledTap,
    this.disabled = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = selected
        ? colorScheme.primary.withValues(alpha: 0.52)
        : colorScheme.outlineVariant;

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 0 : 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: disabled ? onDisabledTap : onTap,
        child: Opacity(
          opacity: disabled && !selected ? 0.58 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? colorScheme.primary.withValues(alpha: 0.1)
                  : colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                _MonitorStatusIcon(sampling: sampling, selected: selected),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connection.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${connection.username}@${connection.host}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurface.withValues(alpha: 0.62),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected) const Icon(Icons.check_rounded, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MonitorStatusIcon extends StatelessWidget {
  final bool sampling;
  final bool selected;
  final bool compact;

  const _MonitorStatusIcon({
    required this.sampling,
    this.selected = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = compact ? 28.0 : 30.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.16)
            : colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: selected
            ? Border.all(color: colorScheme.primary.withValues(alpha: 0.42))
            : null,
      ),
      child: sampling
          ? Padding(
              padding: EdgeInsets.all(compact ? 7 : 8),
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.monitor_heart_outlined,
              color: colorScheme.primary,
              size: compact ? 17 : 19,
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
  final Future<void> Function() onStartMonitoring;

  const _MonitorContent({
    required this.strings,
    required this.monitor,
    required this.tabIndex,
    required this.selectionVersion,
    required this.selectedConnections,
    required this.monitoringConnections,
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
  final Set<String> _collapsedChartKeys = {};

  AppStrings get strings => widget.strings;
  PerformanceMonitorService get monitor => widget.monitor;
  List<ConnectionConfig> get activeConnections {
    if (widget.tabIndex == 0) {
      return monitor.isRunning
          ? widget.monitoringConnections
          : widget.selectedConnections;
    }
    return widget.selectedConnections;
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
      _portsFuture = widget.selectedConnections.isEmpty ? null : _loadPorts();
    } else if (widget.tabIndex == 2) {
      _appsFuture =
          widget.selectedConnections.isEmpty ? null : _loadApplications();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (monitor.isRunning && !_wasRunning) {
      _configExpanded = false;
    }
    _wasRunning = monitor.isRunning;

    return Column(
      children: [
        if (widget.tabIndex == 0)
          _MonitorConfigPanelV2(
            strings: strings,
            monitor: monitor,
            serversPerChart: _serversPerChart,
            onStartMonitoring: widget.onStartMonitoring,
            expanded: _configExpanded,
            onToggle: () => setState(() => _configExpanded = !_configExpanded),
            onServersPerChartChanged: (value) {
              setState(() => _serversPerChart = value);
            },
            onCustomInterval: () => _showCustomDuration(
              title: _monitorText(strings, 'Interval', '刷新间隔'),
              initial: monitor.interval,
              onChanged: monitor.setInterval,
            ),
            onCustomWindow: () => _showCustomDuration(
              title: _monitorText(strings, 'Range', '时间范围'),
              initial: monitor.historyWindow,
              max: PerformanceMonitorService.maxRetention,
              onChanged: monitor.setHistoryWindow,
            ),
          ),
        Expanded(
          child: IndexedStack(
            index: widget.tabIndex,
            children: [
              _buildPerformanceTab(context),
              _ServerSnapshotTab<PortProcessSnapshot>(
                strings: strings,
                connections: activeConnections,
                emptyText: _monitorText(
                    strings, 'No listening ports found', '未发现监听端口'),
                future: _portsFuture,
                onRefresh: () => setState(() => _portsFuture = _loadPorts()),
                itemBuilder: _buildPortItem,
              ),
              _ServerSnapshotTab<ApplicationMemorySnapshot>(
                strings: strings,
                connections: activeConnections,
                emptyText: _monitorText(
                    strings, 'No application data found', '未发现应用数据'),
                future: _appsFuture,
                onRefresh: () =>
                    setState(() => _appsFuture = _loadApplications()),
                itemBuilder: _buildApplicationItem,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPerformanceTab(BuildContext context) {
    final chartConnections = activeConnections;
    final allSamples = [
      for (final connection in widget.monitoringConnections)
        ...monitor.visibleSamplesFor(connection.id),
    ];
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
    if (allSamples.isEmpty) {
      return Center(
        child: Text(_monitorText(strings, 'Waiting for samples', '等待采样数据')),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 860;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _HealthAlertPanel(
              strings: strings,
              connections: chartConnections,
              monitor: monitor,
            ),
            const SizedBox(height: 12),
            _DiskUsagePanel(
              strings: strings,
              connections: chartConnections,
              monitor: monitor,
              expanded: _diskExpanded,
              onToggle: () => setState(() => _diskExpanded = !_diskExpanded),
            ),
            const SizedBox(height: 12),
            ..._metricCharts(chartConnections, twoColumns),
          ],
        );
      },
    );
  }

  List<Widget> _metricCharts(
    List<ConnectionConfig> chartConnections,
    bool twoColumns,
  ) {
    final specs = [
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
    final widgets = <Widget>[];
    final groupSize = _serversPerChart.clamp(1, 99);
    for (final spec in specs) {
      for (var start = 0; start < chartConnections.length; start += groupSize) {
        final group = chartConnections.skip(start).take(groupSize).toList();
        final key = '${spec.key}-$start';
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _MetricChart(
              title: group.length == chartConnections.length
                  ? spec.title
                  : '${spec.title} ${start + 1}-${start + group.length}',
              unit: spec.unit,
              connections: group,
              monitor: monitor,
              chartHeight: twoColumns ? 178 : 218,
              maxY: spec.maxY,
              valueFor: spec.valueFor,
              latestTextFor: spec.latestTextFor,
              expanded: !_collapsedChartKeys.contains(key),
              onToggle: () {
                setState(() {
                  if (!_collapsedChartKeys.remove(key)) {
                    _collapsedChartKeys.add(key);
                  }
                });
              },
            ),
          ),
        );
      }
    }
    return widgets;
  }

  Future<Map<String, List<PortProcessSnapshot>>> _loadPorts() async {
    final result = <String, List<PortProcessSnapshot>>{};
    for (final connection in activeConnections) {
      result[connection.id] = await monitor.fetchPorts(connection.id);
    }
    return result;
  }

  Future<Map<String, List<ApplicationMemorySnapshot>>>
      _loadApplications() async {
    final result = <String, List<ApplicationMemorySnapshot>>{};
    for (final connection in activeConnections) {
      result[connection.id] = await monitor.fetchApplications(connection.id);
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
      title: Text(
        app.command,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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

class _MetricChart extends StatelessWidget {
  final String title;
  final String unit;
  final List<ConnectionConfig> connections;
  final PerformanceMonitorService monitor;
  final double Function(PerformanceSample sample) valueFor;
  final String Function(PerformanceSample sample) latestTextFor;
  final double chartHeight;
  final double? maxY;
  final bool expanded;
  final VoidCallback onToggle;

  const _MetricChart({
    required this.title,
    required this.unit,
    required this.connections,
    required this.monitor,
    required this.chartHeight,
    required this.valueFor,
    required this.latestTextFor,
    required this.expanded,
    required this.onToggle,
    this.maxY,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final start = _oldestVisibleSampleTime();
    final series = <LineChartBarData>[];
    final latestLabels = <Widget>[];
    var dynamicMax = 1.0;
    var maxX = 10.0;

    for (var i = 0; i < connections.length; i++) {
      final connection = connections[i];
      final samples = monitor.visibleSamplesFor(connection.id);
      if (samples.isEmpty) continue;
      final color = _serverColor(i);
      final spots = [
        for (final sample in samples)
          FlSpot(
            sample.time.difference(start).inMilliseconds / 1000,
            valueFor(sample),
          ),
      ];
      for (final spot in spots) {
        dynamicMax = max(dynamicMax, spot.y);
        maxX = max(maxX, spot.x);
      }
      series.add(
        LineChartBarData(
          spots: spots,
          isCurved: true,
          barWidth: 2,
          color: color,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: color.withValues(alpha: 0.08),
          ),
        ),
      );
      final latest = samples.last;
      latestLabels.add(
        _LegendLabel(
          color: color,
          text: '${connection.name} ${latestTextFor(latest)}',
        ),
      );
    }

    final chartMaxY = maxY ?? max(1, dynamicMax * 1.2);
    final leftInterval = max(1.0, chartMaxY / 4);
    final bottomInterval = max(10.0, maxX / 4);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  unit,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                ),
              ],
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 26,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: latestLabels.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) => latestLabels[index],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: chartHeight,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: maxX,
                  minY: 0,
                  maxY: chartMaxY,
                  clipData: const FlClipData.all(),
                  lineTouchData: const LineTouchData(enabled: false),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 36,
                        interval: leftInterval,
                        getTitlesWidget: (value, meta) => Text(
                          value >= 100
                              ? value.toStringAsFixed(0)
                              : value.toStringAsFixed(1),
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 20,
                        interval: bottomInterval,
                        getTitlesWidget: (value, meta) => Text(
                          '${value.round()}s',
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  lineBarsData: series,
                ),
                duration: const Duration(milliseconds: 180),
              ),
            ),
          ],
        ],
      ),
    );
  }

  DateTime _oldestVisibleSampleTime() {
    DateTime? oldest;
    for (final connection in connections) {
      final samples = monitor.visibleSamplesFor(connection.id);
      if (samples.isEmpty) continue;
      final first = samples.first.time;
      if (oldest == null || first.isBefore(oldest)) oldest = first;
    }
    return oldest ?? DateTime.now();
  }

  Color _serverColor(int index) => _monitorSeriesColor(index);
}

class _LegendLabel extends StatelessWidget {
  final Color color;
  final String text;

  const _LegendLabel({
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MetricSpec {
  final String key;
  final String title;
  final String unit;
  final double Function(PerformanceSample sample) valueFor;
  final String Function(PerformanceSample sample) latestTextFor;
  final double? maxY;

  const _MetricSpec({
    required this.key,
    required this.title,
    required this.unit,
    required this.valueFor,
    required this.latestTextFor,
    this.maxY,
  });
}

class _MonitorTopTabs extends StatelessWidget {
  final int selectedIndex;
  final AppStrings strings;
  final ValueChanged<int> onChanged;

  const _MonitorTopTabs({
    required this.selectedIndex,
    required this.strings,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Center(
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                      value: 0,
                      icon: const Icon(Icons.monitor_heart_outlined),
                      label: Text(_monitorText(strings, 'Performance', '性能监控')),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: const Icon(Icons.hub_outlined),
                      label: Text(_monitorText(strings, 'Ports', '端口监控')),
                    ),
                    ButtonSegment(
                      value: 2,
                      icon: const Icon(Icons.apps_rounded),
                      label: Text(
                        _monitorText(strings, 'Applications', '应用监控'),
                      ),
                    ),
                  ],
                  selected: {selectedIndex},
                  onSelectionChanged: (values) => onChanged(values.first),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MonitorConfigPanelV2 extends StatelessWidget {
  final AppStrings strings;
  final PerformanceMonitorService monitor;
  final int serversPerChart;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<void> Function() onStartMonitoring;
  final ValueChanged<int> onServersPerChartChanged;
  final VoidCallback onCustomInterval;
  final VoidCallback onCustomWindow;

  const _MonitorConfigPanelV2({
    required this.strings,
    required this.monitor,
    required this.serversPerChart,
    required this.expanded,
    required this.onToggle,
    required this.onStartMonitoring,
    required this.onServersPerChartChanged,
    required this.onCustomInterval,
    required this.onCustomWindow,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.tune_rounded,
                      color: colorScheme.primary,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _headerTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _headerSubtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (monitor.isSampling)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _monitorText(strings, 'Sampling', '采样中'),
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  IconButton(
                    tooltip: expanded
                        ? _monitorText(strings, 'Collapse', '收起')
                        : _monitorText(strings, 'Expand', '展开'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                    onPressed: onToggle,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState:
                expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            secondChild: const SizedBox(width: double.infinity),
            firstChild: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 760;
                final sections = [
                  _MonitorConfigSection(
                    icon: Icons.schedule_rounded,
                    title: _monitorText(strings, 'Sampling', '采样'),
                    subtitle: _monitorText(
                      strings,
                      'Interval and manual refresh',
                      '刷新间隔与手动采样',
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _DurationMenu(
                          label: _monitorText(strings, 'Interval', '刷新间隔'),
                          value: monitor.interval,
                          values: PerformanceMonitorService.intervalOptions,
                          onChanged: monitor.setInterval,
                          onCustom: onCustomInterval,
                          strings: strings,
                        ),
                        IconButton.outlined(
                          tooltip: monitor.isSampling
                              ? _monitorText(strings, 'Sampling...', '正在采样...')
                              : strings.refresh,
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: monitor.isRunning && !monitor.isSampling
                              ? monitor.sampleNow
                              : null,
                        ),
                      ],
                    ),
                  ),
                  _MonitorConfigSection(
                    icon: Icons.query_stats_rounded,
                    title: _monitorText(strings, 'Display', '显示'),
                    subtitle: _monitorText(
                      strings,
                      'Visible range and chart grouping',
                      '时间范围与图表分组',
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _DurationMenu(
                          label: _monitorText(strings, 'Range', '时间范围'),
                          value: monitor.historyWindow,
                          values:
                              PerformanceMonitorService.historyWindowOptions,
                          onChanged: monitor.setHistoryWindow,
                          onCustom: onCustomWindow,
                          strings: strings,
                        ),
                        _ServersPerChartMenu(
                          strings: strings,
                          value: serversPerChart,
                          onChanged: onServersPerChartChanged,
                        ),
                      ],
                    ),
                  ),
                  _MonitorConfigSection(
                    icon: Icons.play_circle_outline_rounded,
                    title: _monitorText(strings, 'Control', '控制'),
                    subtitle: monitor.isRunning
                        ? _monitorText(strings, 'Monitoring is active', '监控运行中')
                        : _monitorText(
                            strings,
                            'Start after selecting servers',
                            '选择服务器后开始',
                          ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: monitor.isRunning ||
                                  monitor.selectedConnectionIds.isEmpty
                              ? null
                              : onStartMonitoring,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(_monitorText(strings, 'Start', '开始')),
                        ),
                        if (monitor.isRunning)
                          OutlinedButton.icon(
                            onPressed: monitor.stopMonitoring,
                            icon: const Icon(Icons.stop_rounded),
                            label: Text(_monitorText(strings, 'Stop', '停止')),
                          ),
                      ],
                    ),
                  ),
                ];
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < sections.length; i++) ...[
                              if (i > 0) const SizedBox(width: 10),
                              Expanded(child: sections[i]),
                            ],
                          ],
                        )
                      : Column(
                          children: [
                            for (var i = 0; i < sections.length; i++) ...[
                              if (i > 0) const SizedBox(height: 10),
                              sections[i],
                            ],
                          ],
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String get _headerTitle {
    if (monitor.isRunning) {
      final count = monitor.monitoringConnectionIds.length;
      return _monitorText(
        strings,
        'Monitoring $count server${count == 1 ? '' : 's'}',
        '正在监控 $count 台服务器',
      );
    }
    final count = monitor.selectedConnectionIds.length;
    return _monitorText(strings, '$count selected', '已选择 $count 台');
  }

  String get _headerSubtitle {
    final duration = _runDurationLabel(monitor.startedAt);
    return monitor.isRunning
        ? '${_monitorText(strings, 'Duration', '监控时长')} $duration · ${_monitorText(strings, 'Effective interval', '当前间隔')} ${_durationLabel(monitor.effectiveInterval)}'
        : '${_monitorText(strings, 'Interval', '刷新间隔')} ${_durationLabel(monitor.interval)} · ${_monitorText(strings, 'Range', '时间范围')} ${_durationLabel(monitor.historyWindow)} · ${_monitorText(strings, 'Per chart', '每图')} $serversPerChart';
  }
}

class _MonitorConfigSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  const _MonitorConfigSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: colorScheme.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _MonitorConfigCard extends StatelessWidget {
  final AppStrings strings;
  final PerformanceMonitorService monitor;
  final int serversPerChart;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<void> Function() onStartMonitoring;
  final ValueChanged<int> onServersPerChartChanged;
  final VoidCallback onCustomInterval;
  final VoidCallback onCustomWindow;

  const _MonitorConfigCard({
    required this.strings,
    required this.monitor,
    required this.serversPerChart,
    required this.expanded,
    required this.onToggle,
    required this.onStartMonitoring,
    required this.onServersPerChartChanged,
    required this.onCustomInterval,
    required this.onCustomWindow,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      monitor.isRunning
                          ? _monitorText(
                              strings,
                              'Monitoring ${monitor.monitoringConnectionIds.length} server${monitor.monitoringConnectionIds.length == 1 ? '' : 's'}',
                              '正在监控 ${monitor.monitoringConnectionIds.length} 台服务器')
                          : _monitorText(
                              strings,
                              '${monitor.selectedConnectionIds.length} selected',
                              '已选择 ${monitor.selectedConnectionIds.length} 台'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '${_monitorText(strings, 'Duration', '监控时长')} ${_runDurationLabel(monitor.startedAt)}  ${_monitorText(strings, 'Effective interval', '当前间隔')} ${_durationLabel(monitor.effectiveInterval)}',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState:
                expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            secondChild: const SizedBox(width: double.infinity),
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _DurationMenu(
                    label: _monitorText(strings, 'Interval', '刷新间隔'),
                    value: monitor.interval,
                    values: PerformanceMonitorService.intervalOptions,
                    onChanged: monitor.setInterval,
                    onCustom: onCustomInterval,
                    strings: strings,
                  ),
                  _DurationMenu(
                    label: _monitorText(strings, 'Range', '时间范围'),
                    value: monitor.historyWindow,
                    values: PerformanceMonitorService.historyWindowOptions,
                    onChanged: monitor.setHistoryWindow,
                    onCustom: onCustomWindow,
                    strings: strings,
                  ),
                  FilledButton.icon(
                    onPressed: monitor.isRunning ||
                            monitor.selectedConnectionIds.isEmpty
                        ? null
                        : onStartMonitoring,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_monitorText(strings, 'Start', '开始监控')),
                  ),
                  if (monitor.isRunning)
                    OutlinedButton.icon(
                      onPressed: monitor.stopMonitoring,
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(_monitorText(strings, 'Stop', '停止监控')),
                    ),
                  IconButton(
                    tooltip: monitor.isSampling
                        ? _monitorText(strings, 'Sampling...', '正在采样...')
                        : strings.refresh,
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: monitor.isRunning && !monitor.isSampling
                        ? monitor.sampleNow
                        : null,
                  ),
                  _ServersPerChartMenu(
                    strings: strings,
                    value: serversPerChart,
                    onChanged: onServersPerChartChanged,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DurationMenu extends StatelessWidget {
  final String label;
  final Duration value;
  final List<Duration> values;
  final ValueChanged<Duration> onChanged;
  final VoidCallback onCustom;
  final AppStrings strings;

  const _DurationMenu({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
    required this.onCustom,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasValue = values.contains(value);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Duration?>(
          value: hasValue ? value : null,
          hint: Text('$label ${_durationLabel(value)}'),
          isDense: true,
          items: [
            for (final duration in values)
              DropdownMenuItem(
                value: duration,
                child: Text('$label ${_durationLabel(duration)}'),
              ),
            DropdownMenuItem(
              value: null,
              child: Text('$label ${_monitorText(strings, 'Custom', '自定义')}'),
            ),
          ],
          onChanged: (duration) {
            if (duration == null) {
              onCustom();
            } else {
              onChanged(duration);
            }
          },
        ),
      ),
    );
  }
}

class _ServersPerChartMenu extends StatelessWidget {
  final AppStrings strings;
  final int value;
  final ValueChanged<int> onChanged;

  const _ServersPerChartMenu({
    required this.strings,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final values = [1, 3, 5];
    final hasPreset = values.contains(value);
    return OutlinedButton.icon(
      icon: const Icon(Icons.stacked_line_chart_rounded),
      label: Text(
        _monitorText(strings, '$value/server chart', '每图 $value 台'),
      ),
      onPressed: () async {
        final selected = await showModalBottomSheet<int>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in values)
                  ListTile(
                    selected: hasPreset && item == value,
                    title: Text(
                      _monitorText(strings, '$item per chart', '每图 $item 台'),
                    ),
                    onTap: () => Navigator.pop(ctx, item),
                  ),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(_monitorText(strings, 'Custom', '自定义')),
                  onTap: () async {
                    final custom = await _askCustomCount(ctx, strings, value);
                    if (ctx.mounted && custom != null) {
                      Navigator.pop(ctx, custom);
                    }
                  },
                ),
              ],
            ),
          ),
        );
        if (selected != null) onChanged(selected.clamp(1, 99));
      },
    );
  }

  Future<int?> _askCustomCount(
    BuildContext context,
    AppStrings strings,
    int initial,
  ) async {
    final controller = TextEditingController(text: '$initial');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_monitorText(strings, 'Servers per chart', '每图服务器数量')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: _monitorText(strings, 'Count', '数量'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null && value > 0) Navigator.pop(ctx, value);
            },
            child: Text(strings.save),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

class _DiskUsagePanel extends StatelessWidget {
  final AppStrings strings;
  final List<ConnectionConfig> connections;
  final PerformanceMonitorService monitor;
  final bool expanded;
  final VoidCallback onToggle;

  const _DiskUsagePanel({
    required this.strings,
    required this.connections,
    required this.monitor,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _monitorText(strings, 'Disk usage', '硬盘使用情况'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
              ],
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 10),
            for (var i = 0; i < connections.length; i++)
              _DiskUsageServerBlock(
                connection: connections[i],
                color: _monitorSeriesColor(i),
                disks: monitor.diskUsageFor(connections[i].id),
              ),
          ],
        ],
      ),
    );
  }
}

class _HealthAlertPanel extends StatelessWidget {
  final AppStrings strings;
  final List<ConnectionConfig> connections;
  final PerformanceMonitorService monitor;

  const _HealthAlertPanel({
    required this.strings,
    required this.connections,
    required this.monitor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final alertsById = {
      for (final alert in monitor.alerts.take(20)) alert.connectionId: alert,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.health_and_safety_outlined,
                  size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _monitorText(strings, 'Health and alerts', '健康与告警'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final connection in connections)
                _HealthBadge(
                  strings: strings,
                  connection: connection,
                  health: monitor.healthFor(connection.id),
                  alert: alertsById[connection.id],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HealthBadge extends StatelessWidget {
  final AppStrings strings;
  final ConnectionConfig connection;
  final ServerHealthSnapshot health;
  final MonitorAlert? alert;

  const _HealthBadge({
    required this.strings,
    required this.connection,
    required this.health,
    this.alert,
  });

  @override
  Widget build(BuildContext context) {
    final color = _healthColor(context, health.level);
    final detail = alert?.message ??
        (health.details.isEmpty
            ? _healthLabel(strings, health.level)
            : health.details.join(' / '));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_healthIcon(health.level), color: color, size: 17),
            const SizedBox(width: 7),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${connection.name} · ${health.score}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiskUsageServerBlock extends StatelessWidget {
  final ConnectionConfig connection;
  final Color color;
  final List<DiskUsageSnapshot> disks;

  const _DiskUsageServerBlock({
    required this.connection,
    required this.color,
    required this.disks,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LegendLabel(color: color, text: connection.name),
          const SizedBox(height: 6),
          if (disks.isEmpty)
            Text('-', style: TextStyle(color: colorScheme.onSurfaceVariant))
          else
            for (final disk in disks.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 82,
                      child: Text(
                        disk.mount,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: disk.usedPercent / 100,
                        color: color,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${disk.usedPercent.toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _ServerSnapshotTab<T> extends StatelessWidget {
  final AppStrings strings;
  final List<ConnectionConfig> connections;
  final String emptyText;
  final Future<Map<String, List<T>>>? future;
  final VoidCallback onRefresh;
  final Widget Function(BuildContext context, T item) itemBuilder;

  const _ServerSnapshotTab({
    required this.strings,
    required this.connections,
    required this.emptyText,
    required this.future,
    required this.onRefresh,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (connections.isEmpty) {
      return Center(
        child: Text(_monitorText(
            strings, 'Select at least one server first.', '请先选择至少一台服务器。')),
      );
    }
    return FutureBuilder<Map<String, List<T>>>(
      future: future,
      builder: (context, snapshot) {
        final isRefreshing =
            snapshot.connectionState == ConnectionState.waiting;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _serverSummary(strings, connections),
                        maxLines: 1,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  IconButton.outlined(
                    onPressed: isRefreshing ? null : onRefresh,
                    icon: isRefreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    tooltip: strings.refresh,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Builder(
                builder: (context) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        '${_monitorText(strings, 'Load failed', '鍔犺浇澶辫触')}: ${snapshot.error}',
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  final data = snapshot.data ?? const {};
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    children: [
                      for (final connection in connections)
                        _ServerSnapshotSection<T>(
                          connection: connection,
                          items: data[connection.id] ?? const [],
                          emptyText: emptyText,
                          itemBuilder: itemBuilder,
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PortProcessTile extends StatefulWidget {
  final AppStrings strings;
  final PortProcessSnapshot port;

  const _PortProcessTile({
    required this.strings,
    required this.port,
  });

  @override
  State<_PortProcessTile> createState() => _PortProcessTileState();
}

class _PortProcessTileState extends State<_PortProcessTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final port = widget.port;
    final portText = port.port == 0 ? '-' : '${port.port}';
    final processText = port.process.trim().isEmpty ? '-' : port.process.trim();
    final stateText = port.state.trim().isEmpty ? '-' : port.state.trim();

    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 32,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.22),
                    ),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      portText,
                      maxLines: 1,
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        processText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${port.protocol.toUpperCase()} $stateText  ${port.localAddress}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(78, 0, 12, 10),
            child: Column(
              children: [
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'Address', '地址'),
                  value: port.localAddress,
                ),
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'Protocol', '协议'),
                  value: port.protocol.toUpperCase(),
                ),
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'State', '状态'),
                  value: stateText,
                ),
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'Process', '进程'),
                  value: processText,
                ),
              ],
            ),
          ),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 160),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}

class _PortDetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _PortDetailLine({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerSnapshotSection<T> extends StatelessWidget {
  final ConnectionConfig connection;
  final List<T> items;
  final String emptyText;
  final Widget Function(BuildContext context, T item) itemBuilder;

  const _ServerSnapshotSection({
    required this.connection,
    required this.items,
    required this.emptyText,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text(
              connection.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                emptyText,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            )
          else
            for (final item in items) itemBuilder(context, item),
        ],
      ),
    );
  }
}

class _MonitorResponsiveEmptyState extends StatelessWidget {
  final AppStrings strings;
  final String? message;

  const _MonitorResponsiveEmptyState({
    required this.strings,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 180;
        final showIcon = constraints.maxHeight >= 150;
        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(compact ? 12 : 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showIcon) ...[
                  Container(
                    width: compact ? 44 : 72,
                    height: compact ? 44 : 72,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: colorScheme.primary.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Icon(
                      Icons.monitor_heart_outlined,
                      color: colorScheme.primary,
                      size: compact ? 24 : 34,
                    ),
                  ),
                  SizedBox(height: compact ? 8 : 14),
                ],
                Text(
                  _monitorText(
                      strings, 'Select servers to monitor', '选择要监控的服务器'),
                  textAlign: TextAlign.center,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 14 : 16,
                  ),
                ),
                SizedBox(height: compact ? 4 : 6),
                Text(
                  message ??
                      _monitorText(
                        strings,
                        'Select one or more servers, then start monitoring. Sampling stays silent until started.',
                        '可多选服务器，点击开始监控后才采样；未开始前保持静默。',
                      ),
                  textAlign: TextAlign.center,
                  maxLines: compact ? 2 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: compact ? 12 : 13,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MonitorEmptyState extends StatelessWidget {
  final AppStrings strings;
  final String? message;

  const _MonitorEmptyState({
    required this.strings,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Icon(
                Icons.monitor_heart_outlined,
                color: colorScheme.primary,
                size: 34,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _monitorText(strings, 'Select servers to monitor', '选择要监控的服务器'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message ??
                  _monitorText(
                    strings,
                    'Select one or more servers, then start monitoring. Sampling stays silent until started.',
                    '可多选服务器，点击开始监控后才采样；未开始前保持静默。',
                  ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
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
