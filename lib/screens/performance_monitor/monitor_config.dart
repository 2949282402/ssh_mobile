part of '../performance_monitor_screen.dart';

class _MonitorConfigPanelV2 extends StatelessWidget {
  final AppStrings strings;
  final PerformanceMonitorViewModel monitor;
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
                        OverflowScrollText(
                          _headerTitle,
                          selectable: false,
                          maxLines: 1,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        OverflowScrollText(
                          _headerSubtitle,
                          selectable: false,
                          maxLines: 1,
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
                          values: PerformanceMonitorViewModel.intervalOptions,
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
                              PerformanceMonitorViewModel.historyWindowOptions,
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
