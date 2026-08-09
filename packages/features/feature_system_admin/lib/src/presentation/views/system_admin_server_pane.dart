// System Admin 服务器选择和连接状态面板。

part of 'system_admin_screen.dart';

class _AdminConnectionStatusSnapshot {
  final bool selected;
  final bool busy;
  final bool connected;

  const _AdminConnectionStatusSnapshot({
    required this.selected,
    required this.busy,
    required this.connected,
  });

  factory _AdminConnectionStatusSnapshot.from(
    SystemAdminViewModel viewModel,
    String? connectionId,
  ) {
    if (connectionId == null || connectionId.isEmpty) {
      return const _AdminConnectionStatusSnapshot(
        selected: false,
        busy: false,
        connected: false,
      );
    }
    return _AdminConnectionStatusSnapshot(
      selected: viewModel.selectedConnectionId == connectionId,
      busy:
          viewModel.managementConnectionId == connectionId &&
          viewModel.isConnecting,
      connected:
          viewModel.managementConnectionId == connectionId &&
          viewModel.isConnected,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _AdminConnectionStatusSnapshot &&
        other.selected == selected &&
        other.busy == busy &&
        other.connected == connected;
  }

  @override
  int get hashCode => Object.hash(selected, busy, connected);
}

class _MonitorConnectionStatusSnapshot {
  final bool selected;
  final bool sampling;
  final bool running;
  final bool connected;

  const _MonitorConnectionStatusSnapshot({
    required this.selected,
    required this.sampling,
    required this.running,
    required this.connected,
  });

  factory _MonitorConnectionStatusSnapshot.from(
    PerformanceMonitorViewModel monitor,
    String connectionId,
  ) {
    final running = monitor.isRunning;
    final monitoring = monitor.monitoringConnectionIds.contains(connectionId);
    return _MonitorConnectionStatusSnapshot(
      selected: monitor.selectedConnectionIds.contains(connectionId),
      sampling: monitor.isSampling && monitoring,
      running: running,
      connected: monitoring,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MonitorConnectionStatusSnapshot &&
        other.selected == selected &&
        other.sampling == sampling &&
        other.running == running &&
        other.connected == connected;
  }

  @override
  int get hashCode => Object.hash(selected, sampling, running, connected);
}

class _AdminServerPane extends StatelessWidget {
  final AppStrings strings;
  final bool isMonitorTab;
  final VoidCallback onCollapse;

  const _AdminServerPane({
    required this.strings,
    required this.isMonitorTab,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final connections = context
        .select<SystemAdminViewModel, List<ConnectionConfig>>(
          (vm) => vm.connections,
        );
    return ServerSelectorPane(
      connections: connections,
      title: isMonitorTab
          ? _monitorText(strings, 'Monitor servers', '监控服务器')
          : strings.omServers,
      subtitle: _monitorText(
        strings,
        '${connections.length} available',
        '共 ${connections.length} 台可用',
      ),
      headerIcon: isMonitorTab
          ? Icons.monitor_heart_outlined
          : Icons.dns_outlined,
      collapseTooltip: strings.collapseServerList,
      reorderTooltip: strings.reorderServer,
      collapseButtonKey: const ValueKey('admin-server-collapse-desktop'),
      collapseIcon: isMonitorTab
          ? Icons.unfold_less_rounded
          : Icons.keyboard_double_arrow_left_rounded,
      onCollapse: onCollapse,
      onReorder: (oldIndex, newIndex) {
        context
            .read<SystemAdminConnectionCatalogPort>()
            .reorderConnections(oldIndex, newIndex);
      },
      tileBuilder: (context, connection, compact) => _AdminServerTileBinding(
        connection: connection,
        compact: compact,
        isMonitorTab: isMonitorTab,
      ),
      emptyState: _AdminEmptyState(strings: strings),
    );
  }
}

class _AdminMobileServerStrip extends StatelessWidget {
  final AppStrings strings;
  final bool isMonitorTab;
  final VoidCallback onCollapse;

  const _AdminMobileServerStrip({
    super.key,
    required this.strings,
    required this.isMonitorTab,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final connections = context
        .select<SystemAdminViewModel, List<ConnectionConfig>>(
          (vm) => vm.connections,
        );
    return ServerSelectorStrip(
      connections: connections,
      semanticsLabel: isMonitorTab
          ? _monitorText(strings, 'Monitor servers', '监控服务器')
          : strings.omServers,
      noConnectionsLabel: strings.noConnections,
      collapseTooltip: strings.collapseServerList,
      collapseButtonKey: const ValueKey('admin-server-collapse-mobile'),
      collapseIcon: isMonitorTab
          ? Icons.unfold_less_rounded
          : Icons.keyboard_double_arrow_up_rounded,
      onCollapse: onCollapse,
      tileBuilder: (context, connection, compact) => _AdminServerTileBinding(
        connection: connection,
        compact: compact,
        isMonitorTab: isMonitorTab,
      ),
    );
  }
}

class _AdminCollapsedMobileServerBar extends StatelessWidget {
  final AppStrings strings;
  final bool isMonitorTab;
  final VoidCallback onExpand;

  const _AdminCollapsedMobileServerBar({
    super.key,
    required this.strings,
    required this.isMonitorTab,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 2.0).toDouble();
    final barHeight = 48.0 + (textScale - 1.0) * 22.0;

    final selectedConnectionId = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );
    final selectedConnection = selectedConnectionId != null
        ? context.select<SystemAdminViewModel, ConnectionConfig?>(
            (vm) => vm.connectionById(selectedConnectionId),
          )
        : null;

    final connections = context
        .select<SystemAdminViewModel, List<ConnectionConfig>>(
          (vm) => vm.connections,
        );

    final selectedMonitorIds = context
        .select<PerformanceMonitorViewModel, Set<String>>(
          (vm) => vm.selectedConnectionIds,
        );

    final selectedMonitorConnections = connections
        .where((c) => selectedMonitorIds.contains(c.id))
        .toList();

    final monitorIsRunning = context.select<PerformanceMonitorViewModel, bool>(
      (vm) => vm.isRunning,
    );
    final monitorIsSampling = context.select<PerformanceMonitorViewModel, bool>(
      (vm) => vm.isSampling,
    );

    final adminManagementId = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.managementConnectionId,
    );
    final adminIsConnecting = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnecting,
    );
    final adminIsConnected = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnected,
    );

    final bool busy;
    final bool connected;

    if (isMonitorTab) {
      busy = monitorIsSampling && monitorIsRunning;
      connected = monitorIsRunning;
    } else {
      busy = adminIsConnecting && adminManagementId == selectedConnectionId;
      connected = adminIsConnected && adminManagementId == selectedConnectionId;
    }

    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: barHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    key: const ValueKey('admin-server-expand-mobile'),
                    tooltip: strings.expandServerList,
                    icon: Icon(
                      isMonitorTab
                          ? Icons.unfold_more_rounded
                          : Icons.keyboard_double_arrow_down_rounded,
                    ),
                    onPressed: onExpand,
                  ),
                ),
                _AdminServerStatusIcon(
                  busy: busy,
                  connected: connected,
                  compact: true,
                  isMonitorTab: isMonitorTab,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OverflowScrollText(
                    isMonitorTab
                        ? _serverSummary(strings, selectedMonitorConnections)
                        : (selectedConnection == null
                              ? strings.omServers
                              : '${selectedConnection.name}  ${selectedConnection.username}@${selectedConnection.host}'),
                    selectable: false,
                    maxLines: 1,
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

class _AdminCollapsedDesktopServerRail extends StatelessWidget {
  final AppStrings strings;
  final bool isMonitorTab;
  final VoidCallback onExpand;

  const _AdminCollapsedDesktopServerRail({
    super.key,
    required this.strings,
    required this.isMonitorTab,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final selectedConnectionId = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );
    final selectedConnection = selectedConnectionId != null
        ? context.select<SystemAdminViewModel, ConnectionConfig?>(
            (vm) => vm.connectionById(selectedConnectionId),
          )
        : null;

    final connections = context
        .select<SystemAdminViewModel, List<ConnectionConfig>>(
          (vm) => vm.connections,
        );

    final selectedMonitorIds = context
        .select<PerformanceMonitorViewModel, Set<String>>(
          (vm) => vm.selectedConnectionIds,
        );

    final selectedMonitorConnections = connections
        .where((c) => selectedMonitorIds.contains(c.id))
        .toList();

    final monitorIsRunning = context.select<PerformanceMonitorViewModel, bool>(
      (vm) => vm.isRunning,
    );
    final monitorIsSampling = context.select<PerformanceMonitorViewModel, bool>(
      (vm) => vm.isSampling,
    );

    final adminManagementId = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.managementConnectionId,
    );
    final adminIsConnecting = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnecting,
    );
    final adminIsConnected = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.isConnected,
    );

    final bool busy;
    final bool connected;

    if (isMonitorTab) {
      busy = monitorIsSampling && monitorIsRunning;
      connected = monitorIsRunning;
    } else {
      busy = adminIsConnecting && adminManagementId == selectedConnectionId;
      connected = adminIsConnected && adminManagementId == selectedConnectionId;
    }

    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 8),
          SizedBox.square(
            dimension: 48,
            child: IconButton(
              key: const ValueKey('admin-server-expand-desktop'),
              tooltip: strings.expandServerList,
              icon: Icon(
                isMonitorTab
                    ? Icons.unfold_more_rounded
                    : Icons.keyboard_double_arrow_right_rounded,
              ),
              onPressed: onExpand,
            ),
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: isMonitorTab
                ? _serverSummary(strings, selectedMonitorConnections)
                : (selectedConnection == null
                      ? strings.omServers
                      : '${selectedConnection.name}\n${selectedConnection.username}@${selectedConnection.host}'),
            child: _AdminServerStatusIcon(
              busy: busy,
              connected: connected,
              selected: isMonitorTab
                  ? selectedMonitorConnections.isNotEmpty
                  : selectedConnection != null,
              isMonitorTab: isMonitorTab,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminServerStatusIcon extends StatelessWidget {
  final bool busy;
  final bool connected;
  final bool selected;
  final bool compact;
  final bool isMonitorTab;
  final Color? seriesColor;

  const _AdminServerStatusIcon({
    required this.busy,
    required this.connected,
    this.selected = false,
    this.compact = false,
    required this.isMonitorTab,
    this.seriesColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final scale = mobileUiScaleOf(context);
    final size = (compact ? 30.0 : 38.0) * scale;
    final iconSize = (compact ? 18.0 : 22.0) * scale;
    final themeColor = seriesColor ?? colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? themeColor.withValues(alpha: 0.16)
            : themeColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: selected
            ? Border.all(color: themeColor.withValues(alpha: 0.42))
            : null,
      ),
      child: busy
          ? Padding(
              padding: EdgeInsets.all(compact ? 7 * scale : 10 * scale),
              child: CircularProgressIndicator(strokeWidth: 2 * scale),
            )
          : Icon(
              isMonitorTab
                  ? (connected
                        ? Icons.monitor_heart_rounded
                        : Icons.monitor_heart_outlined)
                  : (connected
                        ? Icons.admin_panel_settings_rounded
                        : Icons.admin_panel_settings_outlined),
              color: themeColor,
              size: iconSize,
            ),
    );
  }
}

class _AdminServerTile extends StatelessWidget {
  final ConnectionConfig connection;
  final bool selected;
  final bool busy;
  final bool connected;
  final bool compact;
  final bool isMonitorTab;
  final VoidCallback onTap;
  final Color? seriesColor;

  const _AdminServerTile({
    required this.connection,
    required this.selected,
    required this.busy,
    required this.connected,
    required this.onTap,
    required this.isMonitorTab,
    this.compact = false,
    this.seriesColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final scale = mobileUiScaleOf(context);
    final strings = context.read<AppSettings>().strings;
    final themeColor = seriesColor ?? colorScheme.primary;
    final borderColor = selected
        ? themeColor.withValues(alpha: 0.54)
        : colorScheme.outlineVariant;

    final statusLabel = _adminConnectionStatusLabel(
      strings,
      busy: busy,
      connected: connected,
    );

    return Semantics(
      key: ValueKey('admin-server-tile-${connection.id}'),
      button: true,
      selected: selected,
      label: '${connection.name}, $statusLabel',
      child: Padding(
        padding: EdgeInsets.only(bottom: compact ? 0 : 8 * scale),
        child: TactileFeedback(
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minHeight: compact ? 56 : 72),
            padding: EdgeInsets.symmetric(
              horizontal: 10 * scale,
              vertical: compact ? 3 * scale : 8 * scale,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? themeColor.withValues(alpha: 0.08)
                  : colorScheme.surface,
              borderRadius: BorderRadius.circular(
                compact ? AppTheme.radiusSmall : AppTheme.radiusMedium,
              ),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 30 * scale,
                  height: 30 * scale,
                  alignment: Alignment.center,
                  child: _AdminServerStatusIcon(
                    busy: busy,
                    connected: connected,
                    selected: selected,
                    compact: true,
                    isMonitorTab: isMonitorTab,
                    seriesColor: seriesColor,
                  ),
                ),
                SizedBox(width: 8 * scale),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OverflowScrollText(
                        connection.name,
                        selectable: false,
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 3 * scale),
                      OverflowScrollText(
                        '${connection.username}@${connection.host}',
                        selectable: false,
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurface.withValues(alpha: 0.62),
                          fontSize: 12,
                        ),
                      ),
                      if (!compact) ...[
                        SizedBox(height: 4 * scale),
                        Container(
                          constraints: const BoxConstraints(minHeight: 22),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: themeColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusPill,
                            ),
                          ),
                          child: Text(
                            statusLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: themeColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isMonitorTab && selected) ...[
                  SizedBox(width: 8 * scale),
                  Icon(Icons.check_rounded, size: 18 * scale),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _adminConnectionStatusLabel(
  AppStrings strings, {
  required bool busy,
  required bool connected,
}) {
  if (busy) return strings.connectingEllipsis;
  if (connected) return strings.connected;
  return strings.notConnected;
}

class _AdminServerTileBinding extends StatelessWidget {
  final ConnectionConfig connection;
  final bool compact;
  final bool isMonitorTab;

  const _AdminServerTileBinding({
    required this.connection,
    this.compact = false,
    required this.isMonitorTab,
  });

  @override
  Widget build(BuildContext context) {
    if (isMonitorTab) {
      return Selector<
        PerformanceMonitorViewModel,
        _MonitorConnectionStatusSnapshot
      >(
        selector: (_, monitor) =>
            _MonitorConnectionStatusSnapshot.from(monitor, connection.id),
        builder: (context, status, _) {
          final monitor = context.read<PerformanceMonitorViewModel>();
          final connections = context
              .select<SystemAdminViewModel, List<ConnectionConfig>>(
                (vm) => vm.connections,
              );
          final index = connections.indexWhere((c) => c.id == connection.id);
          final seriesColor = index != -1 ? _monitorSeriesColor(index) : null;
          return _AdminServerTile(
            connection: connection,
            selected: status.selected,
            busy: status.sampling && status.running,
            connected: status.connected,
            compact: compact,
            isMonitorTab: true,
            seriesColor: seriesColor,
            onTap: () {
              if (status.running) {
                final strings = context.read<AppSettings>().strings;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      strings.language == AppLanguage.en
                          ? 'Stop monitoring before changing server selection.'
                          : '请先结束监控后再重新选择服务器。',
                    ),
                  ),
                );
                return;
              }
              monitor.toggleSelection(connection.id);
            },
          );
        },
      );
    } else {
      return Selector<SystemAdminViewModel, _AdminConnectionStatusSnapshot>(
        selector: (_, viewModel) =>
            _AdminConnectionStatusSnapshot.from(viewModel, connection.id),
        builder: (context, status, _) => _AdminServerTile(
          connection: connection,
          selected: status.selected,
          busy: status.busy,
          connected: status.connected,
          compact: compact,
          isMonitorTab: false,
          onTap: () {
            final viewModel = context.read<SystemAdminViewModel>();
            viewModel.selectConnection(connection.id);
            viewModel.setServersCollapsed(context, true);
          },
        ),
      );
    }
  }
}
