part of 'system_admin_screen.dart';

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 760;
          if (isWide) {
            return _buildDesktopToolbar(context, colorScheme);
          } else {
            return _buildMobileToolbar(context, colorScheme);
          }
        },
      ),
    );
  }

  Widget _buildDesktopToolbar(BuildContext context, ColorScheme colorScheme) {
    final isRunning = monitor.isRunning;
    final isSampling = monitor.isSampling;
    final selectedCount = monitor.selectedConnectionIds.length;
    final monitoringCount = monitor.monitoringConnectionIds.length;
    final statusColor = isRunning ? Colors.green.shade600 : colorScheme.outline;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (isRunning)
            _PulsingDot(color: statusColor)
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor,
              ),
            ),
          const SizedBox(width: 8),
          Text(
            isRunning
                ? _monitorText(strings, 'Live', '监控运行中')
                : _monitorText(strings, 'Ready', '准备就绪'),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: isRunning ? Colors.green.shade700 : colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorScheme.primary.withValues(alpha: 0.18)),
            ),
            child: Text(
              isRunning
                  ? _monitorText(strings, '$monitoringCount servers', '监控中 $monitoringCount 台')
                  : _monitorText(strings, '$selectedCount selected', '已选择 $selectedCount 台'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              ),
            ),
          ),
          if (isRunning) ...[
            const SizedBox(width: 10),
            _DurationTracker(startedAt: monitor.startedAt, strings: strings),
          ],
          const Spacer(),
          _DurationMenu(
            icon: Icons.timer_outlined,
            label: _monitorText(strings, 'Interval', '刷新间隔'),
            value: monitor.interval,
            values: PerformanceMonitorViewModel.intervalOptions,
            onChanged: monitor.setInterval,
            onCustom: onCustomInterval,
            strings: strings,
          ),
          const SizedBox(width: 8),
          _DurationMenu(
            icon: Icons.history_rounded,
            label: _monitorText(strings, 'Range', '时间范围'),
            value: monitor.historyWindow,
            values: PerformanceMonitorViewModel.historyWindowOptions,
            onChanged: monitor.setHistoryWindow,
            onCustom: onCustomWindow,
            strings: strings,
          ),
          const SizedBox(width: 8),
          _ServersPerChartMenu(
            strings: strings,
            value: serversPerChart,
            onChanged: onServersPerChartChanged,
          ),
          const SizedBox(width: 8),
          if (isSampling)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
            )
          else if (isRunning)
            IconButton(
              tooltip: strings.refresh,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: monitor.isSampling ? null : monitor.sampleNow,
            ),
          const SizedBox(width: 8),
          if (!isRunning)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                foregroundColor: Colors.white,
              ),
              onPressed: selectedCount == 0 ? null : onStartMonitoring,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(_monitorText(strings, 'Start', '开始')),
            )
          else
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
              ),
              onPressed: monitor.stopMonitoring,
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: Text(_monitorText(strings, 'Stop', '停止')),
            ),
        ],
      ),
    );
  }

  Widget _buildMobileToolbar(BuildContext context, ColorScheme colorScheme) {
    final isRunning = monitor.isRunning;
    final isSampling = monitor.isSampling;
    final selectedCount = monitor.selectedConnectionIds.length;
    final monitoringCount = monitor.monitoringConnectionIds.length;
    final statusColor = isRunning ? Colors.green.shade600 : colorScheme.outline;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (isRunning)
                _PulsingDot(color: statusColor)
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isRunning
                          ? _monitorText(strings, 'Live Monitoring', '监控中')
                          : _monitorText(strings, 'Ready', '准备就绪'),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: isRunning ? Colors.green.shade700 : colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          isRunning
                              ? _monitorText(strings, '$monitoringCount servers', '监控 $monitoringCount 台')
                              : _monitorText(strings, '$selectedCount servers selected', '已选择 $selectedCount 台'),
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (isRunning) ...[
                          const SizedBox(width: 8),
                          Text('•', style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
                          const SizedBox(width: 8),
                          _DurationTracker(startedAt: monitor.startedAt, strings: strings),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                isSelected: expanded,
                icon: Icon(
                  Icons.tune_rounded,
                  color: expanded ? colorScheme.primary : colorScheme.onSurfaceVariant,
                ),
                onPressed: onToggle,
                tooltip: _monitorText(strings, 'Settings', '设置'),
              ),
              if (!isRunning)
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: selectedCount == 0 ? null : onStartMonitoring,
                  icon: const Icon(Icons.play_arrow_rounded),
                )
              else
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: colorScheme.error,
                    foregroundColor: colorScheme.onError,
                  ),
                  onPressed: monitor.stopMonitoring,
                  icon: const Icon(Icons.stop_rounded),
                ),
            ],
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          secondChild: const SizedBox(width: double.infinity),
          firstChild: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
              border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5))),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _DurationMenu(
                  icon: Icons.timer_outlined,
                  label: _monitorText(strings, 'Interval', '刷新间隔'),
                  value: monitor.interval,
                  values: PerformanceMonitorViewModel.intervalOptions,
                  onChanged: monitor.setInterval,
                  onCustom: onCustomInterval,
                  strings: strings,
                ),
                _DurationMenu(
                  icon: Icons.history_rounded,
                  label: _monitorText(strings, 'Range', '时间范围'),
                  value: monitor.historyWindow,
                  values: PerformanceMonitorViewModel.historyWindowOptions,
                  onChanged: monitor.setHistoryWindow,
                  onCustom: onCustomWindow,
                  strings: strings,
                ),
                _ServersPerChartMenu(
                  strings: strings,
                  value: serversPerChart,
                  onChanged: onServersPerChartChanged,
                ),
                if (isRunning)
                  IconButton.outlined(
                    tooltip: strings.refresh,
                    icon: isSampling
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.primary,
                            ),
                          )
                        : const Icon(Icons.refresh_rounded),
                    onPressed: isSampling ? null : monitor.sampleNow,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.35 * (1 - _controller.value)),
              ),
            ),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.55 * (1 - _controller.value)),
              ),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DurationTracker extends StatefulWidget {
  final DateTime? startedAt;
  final AppStrings strings;

  const _DurationTracker({required this.startedAt, required this.strings});

  @override
  State<_DurationTracker> createState() => _DurationTrackerState();
}

class _DurationTrackerState extends State<_DurationTracker> {
  Timer? _timer;
  late ValueNotifier<String> _durationNotifier;

  @override
  void initState() {
    super.initState();
    _durationNotifier = ValueNotifier<String>(_runDurationLabel(widget.startedAt));
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        _durationNotifier.value = _runDurationLabel(widget.startedAt);
      }
    });
  }

  @override
  void didUpdateWidget(_DurationTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt) {
      _durationNotifier.value = _runDurationLabel(widget.startedAt);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _durationNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String>(
      valueListenable: _durationNotifier,
      builder: (context, duration, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              duration,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DurationMenu extends StatelessWidget {
  final IconData icon;
  final String label;
  final Duration value;
  final List<Duration> values;
  final ValueChanged<Duration> onChanged;
  final VoidCallback onCustom;
  final AppStrings strings;

  const _DurationMenu({
    required this.icon,
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
    final displayValue = _durationLabel(value);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<Duration?>(
          tooltip: label,
          offset: const Offset(0, 40),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.8)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  displayValue,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          itemBuilder: (BuildContext context) {
            return [
              for (final duration in values)
                PopupMenuItem<Duration?>(
                  value: duration,
                  child: Text(
                    _durationLabel(duration),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              PopupMenuItem<Duration?>(
                value: null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_outlined, size: 16, color: colorScheme.secondary),
                    const SizedBox(width: 8),
                    Text(
                      _monitorText(strings, 'Custom', '自定义'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ];
          },
          onSelected: (duration) {
            if (duration == null) {
              onCustom();
            } else {
              onChanged(duration);
            }
          },
        ),
      ],
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
    final colorScheme = Theme.of(context).colorScheme;
    final label = _monitorText(strings, 'Per Chart', '每图台数');
    final values = [1, 3, 5];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<int?>(
          tooltip: label,
          offset: const Offset(0, 40),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.8)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.stacked_line_chart_rounded, size: 16, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  _monitorText(strings, '$value', '$value 台'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          itemBuilder: (BuildContext context) {
            return [
              for (final item in values)
                PopupMenuItem<int?>(
                  value: item,
                  child: Text(
                    _monitorText(strings, '$item', '$item 台'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              PopupMenuItem<int?>(
                value: null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_outlined, size: 16, color: colorScheme.secondary),
                    const SizedBox(width: 8),
                    Text(
                      _monitorText(strings, 'Custom', '自定义'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ];
          },
          onSelected: (selected) async {
            if (selected == null) {
              final custom = await _askCustomCount(context, strings, value);
              if (custom != null) {
                onChanged(custom.clamp(1, 99));
              }
            } else {
              onChanged(selected.clamp(1, 99));
            }
          },
        ),
      ],
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
