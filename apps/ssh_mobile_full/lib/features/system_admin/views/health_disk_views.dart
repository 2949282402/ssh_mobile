part of 'system_admin_screen.dart';

/// A compact, data-first overview for the monitor's initial viewport. Keeping
/// health and storage in one panel avoids two large cards before the charts.
class _MonitorOverviewPanel extends StatelessWidget {
  final AppStrings strings;
  final List<ConnectionConfig> connections;
  final PerformanceMonitorViewModel monitor;
  final bool diskExpanded;
  final VoidCallback onDiskToggle;

  const _MonitorOverviewPanel({
    required this.strings,
    required this.connections,
    required this.monitor,
    required this.diskExpanded,
    required this.onDiskToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final alertsById = {
      for (final alert in monitor.alerts.take(20)) alert.connectionId: alert,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIconBadge(
                  icon: Icons.health_and_safety_outlined,
                  size: 32,
                  iconSize: 17,
                  color: colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _monitorText(strings, 'Live overview', '运行概览'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onDiskToggle,
                  icon: Icon(
                    diskExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                  ),
                  label: Text(_monitorText(strings, 'Storage', '存储')),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < connections.length; i++)
                  _HealthBadge(
                    strings: strings,
                    connection: connections[i],
                    seriesColor: _monitorSeriesColor(i),
                    health: monitor.healthFor(connections[i].id),
                    alert: alertsById[connections[i].id],
                  ),
              ],
            ),
            if (diskExpanded) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: colors.outlineVariant),
              ),
              for (var i = 0; i < connections.length; i++)
                _DiskUsageServerBlock(
                  connection: connections[i],
                  color: _monitorSeriesColor(i),
                  disks: monitor.diskUsageFor(connections[i].id),
                ),
            ],
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

class _HealthBadge extends StatelessWidget {
  final AppStrings strings;
  final ConnectionConfig connection;
  final ServerHealthSnapshot health;
  final MonitorAlert? alert;
  final Color seriesColor;

  const _HealthBadge({
    required this.strings,
    required this.connection,
    required this.health,
    required this.seriesColor,
    this.alert,
  });

  @override
  Widget build(BuildContext context) {
    final color = _healthColor(context, health.level);
    final status = _healthLabel(strings, health.level);
    final detail =
        alert?.message ??
        (health.details.isEmpty ? null : health.details.join(' / '));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 4,
                child: Container(color: seriesColor),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 4),
                    Icon(_healthIcon(health.level), color: color, size: 17),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          OverflowScrollText(
                            '${connection.name} · ${health.score} · $status',
                            selectable: false,
                            maxLines: 1,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                          if (detail != null)
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
            ],
          ),
        ),
      ),
    );
  }
}
