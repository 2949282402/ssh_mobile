import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/chat/views/widgets/ai_strings.dart';
import 'package:app_ui/app_ui.dart';

enum _TraceFilter { all, tools, approvals, blocked, errors }

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
    try {
      final storage = context.read<AiStoragePort>();
      final events = await storage.loadAgentTraceEvents(widget.runId);
      final metrics = await storage.loadAgentRunMetrics();
      return _TraceDebugData(
        events: events,
        metrics: metrics.cast<AgentRunMetrics?>().firstWhere(
          (metric) => metric?.id == widget.runId,
          orElse: () => null,
        ),
      );
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Failed to load agent trace',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  void _retry() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);
    return Scaffold(
      appBar: AppBar(title: Text(strings.agentTraceTitle)),
      body: AppPageSurface(
        child: FutureBuilder<_TraceDebugData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return AppSkeletonizer.zone(
                enabled: true,
                semanticsLabel: strings.agentTraceTitle,
                child: const AppSkeletonList(hasLeading: true, itemCount: 6),
              );
            }
            final data = snapshot.data;
            if (snapshot.hasError) {
              return AppEmptyState(
                icon: Icons.error_outline_rounded,
                title: strings.agentTraceLoadFailedTitle,
                message: strings.agentTraceLoadFailedMessage,
                action: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(strings.retry),
                ),
              );
            }
            if (data == null || (data.events.isEmpty && data.metrics == null)) {
              return _EmptyTrace(runId: widget.runId, strings: strings);
            }
            return _TraceDebugBody(
              runId: widget.runId,
              data: data,
              events: _filteredEvents(data.events),
              strings: strings,
              selectedFilter: _filter,
              onFilterSelected: (value) => setState(() => _filter = value),
            );
          },
        ),
      ),
    );
  }

  List<AgentTraceEvent> _filteredEvents(List<AgentTraceEvent> events) {
    return events
        .where((event) {
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
        })
        .toList(growable: false);
  }
}

class _TraceDebugData {
  final List<AgentTraceEvent> events;
  final AgentRunMetrics? metrics;

  const _TraceDebugData({required this.events, required this.metrics});
}

class _TraceDebugBody extends StatelessWidget {
  final String runId;
  final _TraceDebugData data;
  final List<AgentTraceEvent> events;
  final AiStrings strings;
  final _TraceFilter selectedFilter;
  final ValueChanged<_TraceFilter> onFilterSelected;

  const _TraceDebugBody({
    required this.runId,
    required this.data,
    required this.events,
    required this.strings,
    required this.selectedFilter,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = MediaQuery.sizeOf(context).width < 600
        ? AppTheme.compactPagePadding
        : AppTheme.pagePadding;
    final bottomPadding = MediaQuery.paddingOf(context).bottom + 16;

    return CustomScrollView(
      key: const ValueKey('agent-trace-scroll'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            horizontalPadding,
            horizontalPadding,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: _TraceContentWidth(
              child: _OverviewSection(
                runId: runId,
                events: data.events,
                metrics: data.metrics,
                strings: strings,
              ),
            ),
          ),
        ),
        if (data.events.isEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            sliver: SliverToBoxAdapter(
              child: _TraceContentWidth(
                child: _EmptyTrace(runId: runId, strings: strings),
              ),
            ),
          )
        else ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              14,
              horizontalPadding,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: _TraceContentWidth(
                child: _FilterBar(
                  selected: selectedFilter,
                  onSelected: onFilterSelected,
                  strings: strings,
                ),
              ),
            ),
          ),
          if (events.isEmpty)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverToBoxAdapter(
                child: _TraceContentWidth(
                  child: AppEmptyState(
                    icon: Icons.filter_alt_off_outlined,
                    title: strings.agentTraceNoMatchingTitle,
                    message: strings.agentTraceNoMatchingMessage,
                    compact: true,
                    contained: false,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                10,
                horizontalPadding,
                0,
              ),
              sliver: SliverList.builder(
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final event = events[index];
                  return _TraceContentWidth(
                    key: ValueKey('trace-event-${event.id}'),
                    child: _TraceTimelineItem(
                      key: ValueKey(event.id),
                      event: event,
                      strings: strings,
                      offset: event.createdAt.difference(
                        data.events.first.createdAt,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ],
    );
  }
}

class _TraceContentWidth extends StatelessWidget {
  final Widget child;

  const _TraceContentWidth({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

class _OverviewSection extends StatelessWidget {
  final String runId;
  final List<AgentTraceEvent> events;
  final AgentRunMetrics? metrics;
  final AiStrings strings;

  const _OverviewSection({
    required this.runId,
    required this.events,
    required this.metrics,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final summary = _summaryJson(events);
    final finalOutcome = summary['finalOutcome'] as String?;
    final selectedTools = (metrics?.selectedToolSet.isNotEmpty == true)
        ? metrics!.selectedToolSet
        : _stringList(summary['selectedToolSet']);
    final memorySources = (metrics?.memorySources.isNotEmpty == true)
        ? metrics!.memorySources
        : _stringList(summary['memorySources']);
    return AppSectionCard(
      title: strings.agentTraceOverview,
      icon: Icons.analytics_outlined,
      trailing: Text(strings.agentTraceEventCount(events.length)),
      padding: const EdgeInsets.all(14),
      contentGap: 10,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricPill(
                strings.agentTraceMetricStatus,
                _statusLabel(metrics, finalOutcome, strings),
              ),
              _MetricPill(strings.agentTraceMetricRun, runId),
              _MetricPill(
                strings.agentTraceMetricModel,
                metrics?.model ?? '${summary['model'] ?? '-'}',
              ),
              _MetricPill(
                strings.agentTraceMetricHelper,
                metrics?.helperModel ?? '${summary['helperModel'] ?? '-'}',
              ),
              _MetricPill(
                strings.agentTraceMetricAudit,
                metrics?.auditModel ?? '${summary['auditModel'] ?? '-'}',
              ),
              _MetricPill(
                strings.agentTraceMetricElapsed,
                _elapsed(metrics, summary),
              ),
              _MetricPill(
                strings.agentTraceMetricPrompt,
                '${metrics?.promptTokens ?? summary['promptTokens'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricCompletion,
                '${metrics?.completionTokens ?? summary['completionTokens'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricTotal,
                '${metrics?.totalTokens ?? _totalTokens(summary)}',
              ),
              _MetricPill(
                strings.agentTraceMetricTools,
                '${metrics?.toolCalls ?? summary['toolCalls'] ?? _countKind(events, 'tool_request')}',
              ),
              _MetricPill(
                strings.agentTraceMetricCacheHits,
                '${metrics?.cacheHits ?? summary['cacheHits'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricDedupBlocked,
                '${metrics?.dedupBlockedCalls ?? summary['dedupBlockedCalls'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricApprovals,
                '${metrics?.approvalCount ?? summary['approvalCount'] ?? _countKind(events, 'approval')}',
              ),
              _MetricPill(
                strings.agentTraceMetricApproved,
                '${metrics?.approvedCount ?? summary['approvedCount'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricAudits,
                '${metrics?.auditCount ?? summary['auditEscalationLevel'] ?? 0}',
              ),
              _MetricPill(
                strings.agentTraceMetricHelperFanout,
                '${metrics?.helperFanout ?? summary['helperFanout'] ?? 0}',
              ),
            ],
          ),
          if (selectedTools.isNotEmpty) ...[
            const SizedBox(height: 10),
            _SmallLabel(
              strings.agentTraceSelectedTools,
              selectedTools.join(', '),
            ),
          ],
          if (memorySources.isNotEmpty) ...[
            const SizedBox(height: 6),
            _SmallLabel(
              strings.agentTraceMemorySources,
              memorySources.join(', '),
            ),
          ],
          if (finalOutcome != null) ...[
            const SizedBox(height: 10),
            _SmallLabel(
              strings.agentTraceFinalReason,
              _finalOutcomeLabel(finalOutcome, strings),
            ),
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
            for (final entry in decoded.entries) '${entry.key}': entry.value,
          };
        }
      } catch (_) {
        return const {};
      }
    }
    return const {};
  }

  static String _statusLabel(
    AgentRunMetrics? metrics,
    String? finalOutcome,
    AiStrings strings,
  ) {
    if (finalOutcome != null) return _finalOutcomeLabel(finalOutcome, strings);
    if (metrics == null) return strings.unknown;
    return metrics.success
        ? strings.agentTraceStatusSuccess
        : strings.agentTraceStatusFailed;
  }

  static String _elapsed(
    AgentRunMetrics? metrics,
    Map<String, dynamic> summary,
  ) {
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
  final AiStrings strings;

  const _FilterBar({
    required this.selected,
    required this.onSelected,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in _TraceFilter.values)
          ChoiceChip(
            key: ValueKey('trace-filter-${value.name}'),
            label: Text(_filterLabel(value, strings)),
            selected: selected == value,
            onSelected: (_) => onSelected(value),
            visualDensity: VisualDensity.standard,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
      ],
    );
  }
}

class _TraceTimelineItem extends StatelessWidget {
  final AgentTraceEvent event;
  final Duration offset;
  final AiStrings strings;

  const _TraceTimelineItem({
    super.key,
    required this.event,
    required this.offset,
    required this.strings,
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
            key: PageStorageKey<String>('trace-expansion-${event.id}'),
            minTileHeight: 48,
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
              Wrap(
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    key: ValueKey('trace-copy-${event.id}'),
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: event.content));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(strings.agentTraceCopied)),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: Text(strings.agentTraceCopyRaw),
                  ),
                  if (event.truncated)
                    Text(
                      strings.agentTraceTruncated,
                      style: TextStyle(color: colorScheme.error),
                    ),
                ],
              ),
              _TraceRawContent(
                key: ValueKey('trace-raw-content-${event.id}'),
                event: event,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TraceRawContent extends StatefulWidget {
  final AgentTraceEvent event;

  const _TraceRawContent({super.key, required this.event});

  @override
  State<_TraceRawContent> createState() => _TraceRawContentState();
}

class _TraceRawContentState extends State<_TraceRawContent> {
  late final ScrollController _verticalController;

  @override
  void initState() {
    super.initState();
    _verticalController = ScrollController(keepScrollOffset: false);
  }

  @override
  void dispose() {
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('trace-raw-${widget.event.id}'),
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 280),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Scrollbar(
        controller: _verticalController,
        child: SingleChildScrollView(
          controller: _verticalController,
          child: OverflowScrollText(
            widget.event.content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: [
                'Consolas',
                'Microsoft YaHei',
                'PingFang SC',
                'sans-serif',
              ],
              fontSize: 12,
              height: 1.35,
            ),
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
    final maxWidth = (MediaQuery.sizeOf(context).width - 28)
        .clamp(160.0, 420.0)
        .toDouble();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Text(
          '$label: $value',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
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
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _EmptyTrace extends StatelessWidget {
  final String runId;
  final AiStrings strings;

  const _EmptyTrace({required this.runId, required this.strings});

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.account_tree_outlined,
      title: strings.agentTraceEmptyTitle,
      message: runId,
      compact: true,
      contained: false,
    );
  }
}

String _filterLabel(_TraceFilter value, AiStrings strings) {
  switch (value) {
    case _TraceFilter.all:
      return strings.agentTraceFilterAll;
    case _TraceFilter.tools:
      return strings.agentTraceFilterTools;
    case _TraceFilter.approvals:
      return strings.agentTraceFilterApprovals;
    case _TraceFilter.blocked:
      return strings.agentTraceFilterBlocked;
    case _TraceFilter.errors:
      return strings.agentTraceFilterErrors;
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

String _finalOutcomeLabel(String value, AiStrings strings) {
  switch (value) {
    case 'success':
    case 'completed':
    case 'cancelled':
    case 'modelError':
    case 'toolError':
    case 'approvalRejected':
    case 'approvalUnavailable':
    case 'budgetAuditRejected':
    case 'loopGuardBlocked':
    case 'planModeBlocked':
    case 'planExecutionBlocked':
    case 'agentLoopStopped':
      return strings.agentTraceOutcomeLabel(value);
    default:
      return value;
  }
}
