part of '../performance_monitor_screen.dart';

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
                    ButtonSegment(
                      value: 3,
                      icon: const Icon(Icons.settings_suggest_outlined),
                      label: Text(
                        _monitorText(strings, 'Services', '服务监控'),
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

class _MonitorServerPane extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final Set<String> selectedConnectionIds;
  final bool disabled;
  final ValueChanged<String> onConnectionTap;
  final VoidCallback onDisabledTap;
  final VoidCallback onCollapse;

  const _MonitorServerPane({
    required this.connections,
    required this.strings,
    required this.selectedConnectionIds,
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
                        child: Selector<PerformanceMonitorService, bool>(
                          selector: (_, monitor) =>
                              monitor.isSamplingConnection(connection.id),
                          builder: (context, sampling, _) => _MonitorServerTile(
                            connection: connection,
                            selected:
                                selectedConnectionIds.contains(connection.id),
                            sampling: sampling,
                            disabled: disabled,
                            onTap: () => onConnectionTap(connection.id),
                            onDisabledTap: onDisabledTap,
                          ),
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
  final bool disabled;
  final ValueChanged<String> onConnectionTap;
  final VoidCallback onDisabledTap;
  final VoidCallback onCollapse;

  const _MobileMonitorServerStrip({
    super.key,
    required this.connections,
    required this.strings,
    required this.selectedConnectionIds,
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
            child: Selector<PerformanceMonitorService, bool>(
              selector: (_, monitor) =>
                  monitor.isSamplingConnection(connection.id),
              builder: (context, sampling, _) => _MonitorServerTile(
                connection: connection,
                selected: selectedConnectionIds.contains(connection.id),
                sampling: sampling,
                disabled: disabled,
                compact: true,
                onTap: () => onConnectionTap(connection.id),
                onDisabledTap: onDisabledTap,
              ),
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
                  child: OverflowScrollText(
                    _serverSummary(strings, connections),
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
                      OverflowScrollText(
                        connection.name,
                        selectable: false,
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
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
