part of 'message_bubble.dart';

class _AgentRunInlineSummary extends StatefulWidget {
  final String runId;

  const _AgentRunInlineSummary({required this.runId});

  @override
  State<_AgentRunInlineSummary> createState() => _AgentRunInlineSummaryState();
}

class _AgentRunInlineSummaryState extends State<_AgentRunInlineSummary> {
  late Future<_AgentRunInlineData?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _AgentRunInlineSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runId != widget.runId) {
      _future = _load();
    }
  }

  Future<_AgentRunInlineData?> _load() async {
    final storage = context.read<StorageService>();
    final events = await storage.loadAgentTraceEvents(widget.runId);
    final metrics = await storage.loadAgentRunMetrics();
    AgentRunMetrics? metric;
    for (final item in metrics) {
      if (item.id == widget.runId) {
        metric = item;
        break;
      }
    }
    if (metric == null && events.isEmpty) return null;
    return _AgentRunInlineData.from(metric: metric, events: events);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AgentRunInlineData?>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final extColors = theme.extension<ExtendedColors>();
        final isEn = context.read<AppSettings>().language == AppLanguage.en;
        final statusColor = data.success
            ? (extColors?.success ?? colorScheme.primary)
            : colorScheme.error;
        return Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _RunSummaryChip(
                icon: data.success
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                label: data.success
                    ? (isEn ? 'Run completed' : '运行完成')
                    : (isEn ? 'Run needs attention' : '运行需处理'),
                color: statusColor,
              ),
              if (data.toolCalls > 0)
                _RunSummaryChip(
                  icon: Icons.build_outlined,
                  label: isEn
                      ? '${data.toolCalls} tools'
                      : '${data.toolCalls} 个工具',
                  color: colorScheme.primary,
                ),
              if (data.approvalCount > 0)
                _RunSummaryChip(
                  icon: Icons.verified_user_outlined,
                  label: isEn
                      ? '${data.approvedCount}/${data.approvalCount} approvals'
                      : '${data.approvedCount}/${data.approvalCount} 次审批',
                  color: colorScheme.tertiary,
                ),
              if (data.blockedCount > 0)
                _RunSummaryChip(
                  icon: Icons.block_outlined,
                  label: isEn
                      ? '${data.blockedCount} blocked'
                      : '${data.blockedCount} 次阻断',
                  color: colorScheme.error,
                ),
              if (data.elapsedMs != null)
                _RunSummaryChip(
                  icon: Icons.timer_outlined,
                  label: _formatRunElapsed(data.elapsedMs!),
                  color: colorScheme.onSurfaceVariant,
                ),
              if (data.finalOutcome != null)
                _RunSummaryChip(
                  icon: Icons.flag_outlined,
                  label: data.finalOutcome!,
                  color: colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        );
      },
    );
  }

  String _formatRunElapsed(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}

class _AgentRunInlineData {
  final bool success;
  final int toolCalls;
  final int approvalCount;
  final int approvedCount;
  final int blockedCount;
  final int? elapsedMs;
  final String? finalOutcome;

  const _AgentRunInlineData({
    required this.success,
    required this.toolCalls,
    required this.approvalCount,
    required this.approvedCount,
    required this.blockedCount,
    required this.elapsedMs,
    required this.finalOutcome,
  });

  factory _AgentRunInlineData.from({
    required AgentRunMetrics? metric,
    required List<AgentTraceEvent> events,
  }) {
    final blockedCount = events
        .where(
          (event) =>
              event.kind.contains('blocked') ||
              event.status.contains('blocked') ||
              event.status.contains('rejected'),
        )
        .length;
    final toolEvents = events
        .where(
          (event) =>
              event.kind.contains('tool_result') ||
              event.kind.contains('tool_request'),
        )
        .length;
    final approvalEvents = events
        .where((event) => event.kind.contains('approval'))
        .length;
    final finalOutcome = _finalOutcomeFrom(events);
    final success =
        metric?.success ??
        (finalOutcome == null ||
            finalOutcome == 'success' ||
            finalOutcome == 'completed');

    return _AgentRunInlineData(
      success: success,
      toolCalls: metric?.toolCalls ?? toolEvents,
      approvalCount: metric?.approvalCount ?? approvalEvents,
      approvedCount: metric?.approvedCount ?? 0,
      blockedCount: blockedCount,
      elapsedMs: metric?.elapsedMs,
      finalOutcome: finalOutcome,
    );
  }

  static String? _finalOutcomeFrom(List<AgentTraceEvent> events) {
    for (final event in events.reversed) {
      if (event.kind != 'agent_run_summary') continue;
      try {
        final decoded = jsonDecode(event.content);
        if (decoded is Map) {
          final value = decoded['finalOutcome'] ?? decoded['outcome'];
          if (value is String && value.trim().isNotEmpty) {
            return value.trim();
          }
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

class _RunSummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _RunSummaryChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
