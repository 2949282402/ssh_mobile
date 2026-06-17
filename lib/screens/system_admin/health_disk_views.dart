part of '../system_admin_screen.dart';

class _DiskUsagePanel extends StatelessWidget {
  final AppStrings strings;
  final List<ConnectionConfig> connections;
  final PerformanceMonitorViewModel monitor;
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
                      child: OverflowScrollText(
                        disk.mount,
                        selectable: false,
                        maxLines: 1,
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

class _HealthAlertPanel extends StatelessWidget {
  final AppStrings strings;
  final List<ConnectionConfig> connections;
  final PerformanceMonitorViewModel monitor;

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
                  OverflowScrollText(
                    '${connection.name} · ${health.score}',
                    selectable: false,
                    maxLines: 1,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                  OverflowScrollText(
                    detail,
                    selectable: false,
                    maxLines: 1,
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
