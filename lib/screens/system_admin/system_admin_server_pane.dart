part of '../system_admin_screen.dart';

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
      selected: viewModel.connectionId == connectionId,
      busy: viewModel.connectionId == connectionId && viewModel.isConnecting,
      connected:
          viewModel.connectionId == connectionId && viewModel.isConnected,
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

class _AdminServerPane extends StatelessWidget {
  final SystemAdminViewModel viewModel;
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final VoidCallback onCollapse;
  final bool isMonitorTab;

  const _AdminServerPane({
    required this.viewModel,
    required this.connections,
    required this.strings,
    required this.onCollapse,
    required this.isMonitorTab,
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
            _header(context, colorScheme),
            _AdminEmptyState(strings: strings),
          ],
        ),
      );
    }
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          _header(context, colorScheme),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              itemCount: connections.length,
              itemBuilder: (context, index) {
                final connection = connections[index];
                return Container(
                  key: ValueKey(connection.id),
                  margin: const EdgeInsets.only(bottom: 8),
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
                        child: _AdminServerTileBinding(
                          connection: connection,
                          isMonitorTab: isMonitorTab,
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

  Widget _header(BuildContext context, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isMonitorTab
                  ? _monitorText(strings, 'Monitor servers', '监控服务器')
                  : strings.omServers,
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

class _AdminMobileServerStrip extends StatelessWidget {
  final SystemAdminViewModel viewModel;
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final VoidCallback onCollapse;
  final bool isMonitorTab;

  const _AdminMobileServerStrip({
    super.key,
    required this.viewModel,
    required this.connections,
    required this.strings,
    required this.onCollapse,
    required this.isMonitorTab,
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
            return _AdminMobileCollapseButton(
              strings: strings,
              onPressed: onCollapse,
            );
          }
          final connection = connections[index - 1];
          return SizedBox(
            width: 210,
            child: _AdminServerTileBinding(
              connection: connection,
              compact: true,
              isMonitorTab: isMonitorTab,
            ),
          );
        },
      ),
    );
  }
}

class _AdminMobileCollapseButton extends StatelessWidget {
  final AppStrings strings;
  final VoidCallback onPressed;

  const _AdminMobileCollapseButton({
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

class _AdminCollapsedMobileServerBar extends StatelessWidget {
  final ConnectionConfig? selectedConnection;
  final List<ConnectionConfig> connections;
  final bool busy;
  final bool connected;
  final AppStrings strings;
  final VoidCallback onExpand;
  final bool isMonitorTab;

  const _AdminCollapsedMobileServerBar({
    super.key,
    required this.selectedConnection,
    required this.connections,
    required this.busy,
    required this.connected,
    required this.strings,
    required this.onExpand,
    required this.isMonitorTab,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connection = selectedConnection;
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
                        ? _serverSummary(strings, connections)
                        : (connection == null
                            ? strings.omServers
                            : '${connection.name}  ${connection.username}@${connection.host}'),
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
  final ConnectionConfig? selectedConnection;
  final List<ConnectionConfig> connections;
  final bool busy;
  final bool connected;
  final AppStrings strings;
  final VoidCallback onExpand;
  final bool isMonitorTab;

  const _AdminCollapsedDesktopServerRail({
    super.key,
    required this.selectedConnection,
    required this.connections,
    required this.busy,
    required this.connected,
    required this.strings,
    required this.onExpand,
    required this.isMonitorTab,
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
            message: isMonitorTab
                ? _serverSummary(strings, connections)
                : (selectedConnection == null
                    ? strings.omServers
                    : '${selectedConnection!.name}\n${selectedConnection!.username}@${selectedConnection!.host}'),
            child: _AdminServerStatusIcon(
              busy: busy,
              connected: connected,
              selected: isMonitorTab ? connections.isNotEmpty : selectedConnection != null,
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

  const _AdminServerStatusIcon({
    required this.busy,
    required this.connected,
    this.selected = false,
    this.compact = false,
    required this.isMonitorTab,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final scale = mobileUiScaleOf(context);
    final size = (compact ? 30.0 : 38.0) * scale;
    final iconSize = (compact ? 18.0 : 22.0) * scale;
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
              color: colorScheme.primary,
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

  const _AdminServerTile({
    required this.connection,
    required this.selected,
    required this.busy,
    required this.connected,
    required this.onTap,
    required this.isMonitorTab,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final scale = mobileUiScaleOf(context);
    final borderColor = selected
        ? colorScheme.primary.withValues(alpha: 0.54)
        : colorScheme.outlineVariant;

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 0 : 8 * scale),
      child: TactileFeedback(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10 * scale,
            vertical: 8 * scale,
          ),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.12)
                : colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
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
    );
  }
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
      final monitor = context.watch<PerformanceMonitorViewModel>();
      final isSelected = monitor.selectedConnectionIds.contains(connection.id);
      final isSampling = monitor.isSampling && monitor.monitoringConnectionIds.contains(connection.id);
      final isRunning = monitor.isRunning;

      return _AdminServerTile(
        connection: connection,
        selected: isSelected,
        busy: isSampling && isRunning,
        connected: monitor.monitoringConnectionIds.contains(connection.id),
        compact: compact,
        isMonitorTab: true,
        onTap: () {
          if (isRunning) {
            final strings = AppStrings(context.read<AppSettings>().language);
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
          onTap: () =>
              context.read<SystemAdminViewModel>().connect(connection.id),
        ),
      );
    }
  }
}
