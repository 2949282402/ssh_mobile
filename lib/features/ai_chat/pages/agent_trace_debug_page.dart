import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/storage_service.dart';
import '../../../theme/app_theme.dart';
import '../models/agent_trace_event.dart';

enum _TraceFilter {
  all,
  tools,
  approvals,
  blocked,
  errors,
}

class AgentTraceDebugPage extends StatefulWidget {
  final String chatId;
  final String runId;

  const AgentTraceDebugPage({
    super.key,
    required this.chatId,
    required this.runId,
  });

  @override
  State<AgentTraceDebugPage> createState() => _AgentTraceDebugPageState();
}

class _AgentTraceDebugPageState extends State<AgentTraceDebugPage> {
  late Future<_TraceDebugData> _future;
  _TraceFilter _filter = _TraceFilter.all;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_TraceDebugData> _load() async {
    final storage = context.read<StorageService>();
    final events = await storage.loadAgentTraceEvents(widget.runId);
    final metrics = await storage.loadAgentRunMetrics();
    return _TraceDebugData(
      events: events,
      metrics: metrics.cast<AgentRunMetrics?>().firstWhere(
            (metric) => metric?.id == widget.runId,
            orElse: () => null,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent Trace'),
      ),
      body: FutureBuilder<_TraceDebugData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data;
          if (snapshot.hasError) {
            return Center(
              child: Text('Failed to load trace: ${snapshot.error}'),
            );
          }
          if (data == null || (data.events.isEmpty && data.metrics == null)) {
            return _EmptyTrace(runId: widget.runId);
          }
          final events = _filteredEvents(data.events);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _OverviewSection(
                runId: widget.runId,
                events: data.events,
                metrics: data.metrics,
              ),
              const SizedBox(height: 14),
              if (data.events.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.account_tree_outlined, size: 42),
                        const SizedBox(height: 12),
                        const Text(
                          'No persisted trace events found for this run.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.runId,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                _FilterBar(
                  selected: _filter,
                  onSelected: (value) => setState(() => _filter = value),
                ),
                const SizedBox(height: 10),
                if (events.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 36),
                    child: Center(child: Text('No events match this filter.')),
                  )
                else
                  for (final event in events)
                    _TraceTimelineItem(
                      event: event,
                      offset: event.createdAt.difference(
                        data.events.first.createdAt,
                      ),
                    ),
              ],
            ],
          );
        },
      ),
    );
  }

  List<AgentTraceEvent> _filteredEvents(List<AgentTraceEvent> events) {
    return events.where((event) {
      switch (_filter) {
        case _TraceFilter.all:
          return true;
        case _TraceFilter.tools:
          return event.kind.contains('tool') ||
              event.toolName?.trim().isNotEmpty == true;
        case _TraceFilter.approvals:
          return event.kind.contains('approval');
        case _TraceFilter.blocked:
          return event.kind.contains('blocked') ||
              event.status.contains('blocked') ||
              event.status.contains('rejected') ||
              event.status.contains('unavailable');
        case _TraceFilter.errors:
          return event.kind.contains('error') ||
              event.status.contains('error') ||
              event.status.contains('failed');
      }
    }).toList(growable: false);
  }
}

class _TraceDebugData {
  final List<AgentTraceEvent> events;
  final AgentRunMetrics? metrics;

  const _TraceDebugData({
    required this.events,
    required this.metrics,
  });
}

class _OverviewSection extends StatelessWidget {
  final String runId;
  final List<AgentTraceEvent> events;
  final AgentRunMetrics? metrics;

  const _OverviewSection({
    required this.runId,
    required this.events,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final summary = _summaryJson(events);
    final finalOutcome = summary['finalOutcome'] as String?;
    final selectedTools = (metrics?.selectedToolSet.isNotEmpty == true)
        ? metrics!.selectedToolSet
        : _stringList(summary['selectedToolSet']);
    final memorySources = (metrics?.memorySources.isNotEmpty == true)
        ? metrics!.memorySources
        : _stringList(summary['memorySources']);
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics_outlined, color: colorScheme.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Overview',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              Text('${events.length} events'),
            ],
          ),
          const Divider(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricPill('Status', _statusLabel(metrics, finalOutcome)),
              _MetricPill('Run', runId),
              _MetricPill(
                  'Model', metrics?.model ?? '${summary['model'] ?? '-'}'),
              _MetricPill('Helper',
                  metrics?.helperModel ?? '${summary['helperModel'] ?? '-'}'),
              _MetricPill('Audit',
                  metrics?.auditModel ?? '${summary['auditModel'] ?? '-'}'),
              _MetricPill('Elapsed', _elapsed(metrics, summary)),
              _MetricPill('Prompt',
                  '${metrics?.promptTokens ?? summary['promptTokens'] ?? 0}'),
              _MetricPill('Completion',
                  '${metrics?.completionTokens ?? summary['completionTokens'] ?? 0}'),
              _MetricPill(
                  'Total', '${metrics?.totalTokens ?? _totalTokens(summary)}'),
              _MetricPill('Tools',
                  '${metrics?.toolCalls ?? summary['toolCalls'] ?? _countKind(events, 'tool_request')}'),
              _MetricPill('Cache hits',
                  '${metrics?.cacheHits ?? summary['cacheHits'] ?? 0}'),
              _MetricPill('Dedup blocked',
                  '${metrics?.dedupBlockedCalls ?? summary['dedupBlockedCalls'] ?? 0}'),
              _MetricPill('Approvals',
                  '${metrics?.approvalCount ?? summary['approvalCount'] ?? _countKind(events, 'approval')}'),
              _MetricPill('Approved',
                  '${metrics?.approvedCount ?? summary['approvedCount'] ?? 0}'),
              _MetricPill('Audits',
                  '${metrics?.auditCount ?? summary['auditEscalationLevel'] ?? 0}'),
              _MetricPill('Helper fanout',
                  '${metrics?.helperFanout ?? summary['helperFanout'] ?? 0}'),
            ],
          ),
          if (selectedTools.isNotEmpty) ...[
            const SizedBox(height: 10),
            _SmallLabel('Selected tools', selectedTools.join(', ')),
          ],
          if (memorySources.isNotEmpty) ...[
            const SizedBox(height: 6),
            _SmallLabel('Memory sources', memorySources.join(', ')),
          ],
          if (finalOutcome != null) ...[
            const SizedBox(height: 10),
            _SmallLabel('Final reason', _finalOutcomeLabel(finalOutcome)),
          ],
        ],
      ),
    );
  }

  static Map<String, dynamic> _summaryJson(List<AgentTraceEvent> events) {
    for (final event in events.reversed) {
      if (event.kind != 'agent_run_summary') continue;
      try {
        final decoded = jsonDecode(event.content);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) {
          return {
            for (final entry in decoded.entries) '${entry.key}': entry.value
          };
        }
      } catch (_) {
        return const {};
      }
    }
    return const {};
  }

  static String _statusLabel(AgentRunMetrics? metrics, String? finalOutcome) {
    if (finalOutcome != null) return _finalOutcomeLabel(finalOutcome);
    if (metrics == null) return 'Unknown';
    return metrics.success ? 'Success' : 'Failed';
  }

  static String _elapsed(
      AgentRunMetrics? metrics, Map<String, dynamic> summary) {
    final value = metrics?.elapsedMs ?? summary['elapsedMs'];
    if (value is int) return _formatDuration(Duration(milliseconds: value));
    final started = DateTime.tryParse('${summary['startedAt'] ?? ''}');
    final finished = DateTime.tryParse('${summary['finishedAt'] ?? ''}');
    if (started != null && finished != null) {
      return _formatDuration(finished.difference(started));
    }
    return '-';
  }

  static int _totalTokens(Map<String, dynamic> summary) {
    final total = summary['totalTokens'];
    if (total is int) return total;
    final prompt = summary['promptTokens'];
    final completion = summary['completionTokens'];
    return (prompt is int ? prompt : 0) + (completion is int ? completion : 0);
  }

  static int _countKind(List<AgentTraceEvent> events, String kind) {
    return events.where((event) => event.kind == kind).length;
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .whereType<Object>()
          .map((item) => '$item')
          .where((item) => item.trim().isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }
}

class _FilterBar extends StatelessWidget {
  final _TraceFilter selected;
  final ValueChanged<_TraceFilter> onSelected;

  const _FilterBar({
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in _TraceFilter.values)
          ChoiceChip(
            label: Text(_filterLabel(value)),
            selected: selected == value,
            onSelected: (_) => onSelected(value),
          ),
      ],
    );
  }
}

class _TraceTimelineItem extends StatelessWidget {
  final AgentTraceEvent event;
  final Duration offset;

  const _TraceTimelineItem({
    required this.event,
    required this.offset,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final preview = _preview(event.content);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: Icon(
              _iconForKind(event.kind),
              color: _colorForEvent(colorScheme, event),
            ),
            title: Text(
              '${event.sequence}. ${event.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    '+${_formatDuration(offset)}',
                    event.kind,
                    if (event.status.isNotEmpty) event.status,
                    if (event.toolName?.trim().isNotEmpty == true)
                      event.toolName!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (preview.isNotEmpty)
                  Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  preview,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: event.content));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Trace content copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: const Text('Copy raw'),
                  ),
                  if (event.truncated)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        'truncated',
                        style: TextStyle(color: colorScheme.error),
                      ),
                    ),
                ],
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                ),
                child: SelectableText(
                  event.content.isEmpty ? '-' : event.content,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: [
                      'Consolas',
                      'Microsoft YaHei',
                      'PingFang SC',
                      'sans-serif'
                    ],
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  final String label;
  final String value;

  const _MetricPill(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SmallLabel extends StatelessWidget {
  final String label;
  final String value;

  const _SmallLabel(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _EmptyTrace extends StatelessWidget {
  final String runId;

  const _EmptyTrace({required this.runId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_tree_outlined, size: 42),
            const SizedBox(height: 12),
            const Text('No persisted trace events found for this run.'),
            const SizedBox(height: 6),
            Text(
              runId,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _filterLabel(_TraceFilter value) {
  switch (value) {
    case _TraceFilter.all:
      return 'All';
    case _TraceFilter.tools:
      return 'Tools';
    case _TraceFilter.approvals:
      return 'Approvals';
    case _TraceFilter.blocked:
      return 'Blocked';
    case _TraceFilter.errors:
      return 'Errors';
  }
}

IconData _iconForKind(String kind) {
  if (kind == 'tool_exposure') return Icons.inventory_2_outlined;
  if (kind == 'multi_agent' || kind.contains('multi_agent')) {
    return Icons.groups_outlined;
  }
  if (kind == 'tool_request') return Icons.build_circle_outlined;
  if (kind == 'tool_result') return Icons.fact_check_outlined;
  if (kind == 'approval') return Icons.verified_user_outlined;
  if (kind == 'tool_blocked' || kind.contains('blocked')) {
    return Icons.shield_outlined;
  }
  if (kind == 'budget' || kind.contains('audit')) return Icons.warning_amber;
  if (kind == 'agent_run_summary') return Icons.analytics_outlined;
  if (kind == 'error') return Icons.error_outline;
  if (kind.contains('compression')) return Icons.compress_outlined;
  return Icons.info_outline;
}

Color _colorForEvent(ColorScheme colorScheme, AgentTraceEvent event) {
  final status = event.status.toLowerCase();
  if (status.contains('error') ||
      status.contains('failed') ||
      status.contains('rejected')) {
    return colorScheme.error;
  }
  if (status.contains('blocked') || status.contains('unavailable')) {
    return colorScheme.tertiary;
  }
  if (event.kind.contains('tool')) return colorScheme.primary;
  if (event.kind.contains('approval')) return colorScheme.secondary;
  return colorScheme.onSurfaceVariant;
}

String _preview(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= 220) return normalized;
  return '${normalized.substring(0, 220)}...';
}

String _formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(1)}s';
}

String _finalOutcomeLabel(String value) {
  switch (value) {
    case 'success':
      return 'Success';
    case 'cancelled':
      return 'Cancelled by user';
    case 'modelError':
      return 'Model request failed';
    case 'toolError':
      return 'Tool execution failed';
    case 'approvalRejected':
      return 'User rejected approval';
    case 'approvalUnavailable':
      return 'Approval UI unavailable';
    case 'budgetAuditRejected':
      return 'Tool budget audit rejected';
    case 'loopGuardBlocked':
      return 'Tool loop guard blocked execution';
    case 'planModeBlocked':
      return 'Plan Mode blocked execution';
    case 'planExecutionBlocked':
      return 'Plan execution gate blocked execution';
    default:
      return value;
  }
}
