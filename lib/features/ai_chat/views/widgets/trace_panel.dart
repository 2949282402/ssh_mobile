import 'package:flutter/material.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';

class TracePanel extends StatelessWidget {
  final List<AiMessageTrace> traces;
  final String storageKey;

  const TracePanel({
    super.key,
    required this.traces,
    required this.storageKey,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey<String>(storageKey),
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(
            Icons.account_tree_outlined,
            size: 17,
            color: colorScheme.onSurfaceVariant,
          ),
          title: Text(
            '执行详情 (${traces.length})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            for (var i = 0; i < traces.length; i++)
              TraceEntry(
                key: ValueKey<String>('trace-entry-${traces[i].id}'),
                trace: traces[i],
                index: i + 1,
                storageKey: '$storageKey-entry-${traces[i].id}',
              ),
          ],
        ),
      ),
    );
  }
}

class TraceEntry extends StatelessWidget {
  final AiMessageTrace trace;
  final int index;
  final String storageKey;

  const TraceEntry({
    super.key,
    required this.trace,
    required this.index,
    required this.storageKey,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey<String>(storageKey),
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(
            _traceIcon(trace.kind),
            size: 16,
            color: _traceColor(colorScheme, trace.kind),
          ),
          title: Text(
            '$index. ${_traceTitle(trace)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OverflowScrollText(
                trace.content.isEmpty ? '-' : trace.content,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: colorScheme.onSurface.withValues(alpha: 0.82),
                  fontFamily: 'monospace',
                  fontFamilyFallback: const [
                    'Consolas',
                    'Microsoft YaHei',
                    'PingFang SC',
                    'sans-serif'
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _traceTitle(AiMessageTrace trace) {
    switch (trace.kind) {
      case 'reasoning':
        return '深度思考';
      case 'tool_request':
        return '工具调用 - ${trace.title.replaceFirst('Tool request: ', '')}';
      case 'tool_result':
        return '工具结果 - ${trace.title.replaceFirst('Tool result: ', '')}';
      case 'approval':
        return trace.title.contains('approved') ? '工具操作已同意' : '工具操作已拒绝';
      case 'budget':
        final lowerTitle = trace.title.toLowerCase();
        if (lowerTitle.contains('running')) {
          return '工具预算安全审计';
        }
        if (lowerTitle.contains('approved')) {
          return '工具预算审计通过';
        }
        if (lowerTitle.contains('rejected')) {
          return '工具预算已停止';
        }
        return '工具预算提醒';
      default:
        return trace.title;
    }
  }

  IconData _traceIcon(String kind) {
    switch (kind) {
      case 'reasoning':
        return Icons.psychology_alt_outlined;
      case 'rag_context':
        return Icons.auto_stories_outlined;
      case 'tool_request':
        return Icons.build_circle_outlined;
      case 'tool_result':
        return Icons.fact_check_outlined;
      case 'approval':
        return Icons.verified_user_outlined;
      case 'budget':
        return Icons.tune_rounded;
      default:
        return Icons.info_outline;
    }
  }

  Color _traceColor(ColorScheme colorScheme, String kind) {
    switch (kind) {
      case 'reasoning':
        return colorScheme.secondary;
      case 'rag_context':
        return colorScheme.tertiary;
      case 'tool_request':
        return colorScheme.primary;
      case 'tool_result':
        return colorScheme.tertiary;
      case 'approval':
        return colorScheme.error;
      case 'budget':
        return colorScheme.secondary;
      default:
        return colorScheme.onSurfaceVariant;
    }
  }
}
