import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/mcp/mcp_activity.dart';
import '../../../widgets/app_surface.dart';
import '../viewmodels/mcp_console_viewmodel.dart';

class McpActivityScreen extends StatelessWidget {
  const McpActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<McpConsoleViewModel>();
    final english = viewModel.isEnglish;
    return Scaffold(
      body: AppPageSurface(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: AppPageHeader(
                        title: english ? 'Recent activity' : '最近活动',
                        subtitle: english
                            ? 'Redacted MCP server activity'
                            : '已脱敏的 MCP Server 活动记录',
                        icon: Icons.history_rounded,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('mcp-activity-list'),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    _ActivityCard(viewModel: viewModel, english: english),
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

class _ActivityCard extends StatelessWidget {
  final McpConsoleViewModel viewModel;
  final bool english;

  const _ActivityCard({required this.viewModel, required this.english});

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      key: const ValueKey('mcp-recent-activity-card'),
      title: english ? 'Recent activity' : '最近活动',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(english ? 'All' : '全部'),
                selected: viewModel.selectedOutcome == null,
                onSelected: (_) => viewModel.setSelectedOutcome(null),
              ),
              for (final outcome in McpActivityOutcome.values)
                ChoiceChip(
                  label: Text(_activityOutcomeLabel(outcome, english)),
                  selected: viewModel.selectedOutcome == outcome,
                  onSelected: (_) => viewModel.setSelectedOutcome(outcome),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _confirmClear(context),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(english ? 'Clear activity' : '清空活动'),
            ),
          ),
          if (viewModel.activities.isEmpty)
            Text(english ? 'No activity recorded.' : '暂无活动记录。')
          else
            for (final entry in viewModel.activities)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(_activityIcon(entry.kind)),
                title: Text(entry.toolName ?? entry.method ?? entry.kind.name),
                subtitle: Text(
                  [
                    _formatActivityDate(entry.occurredAt),
                    _activityOutcomeLabel(entry.outcome, english),
                    if (entry.policyReason != null) entry.policyReason!,
                    if (entry.durationMs != null) '${entry.durationMs} ms',
                  ].join(' · '),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(english ? 'Clear MCP activity?' : '清空 MCP 活动记录？'),
        content: Text(
          english
              ? 'This only removes local, redacted activity metadata.'
              : '这只会移除本机保存的脱敏活动元数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(english ? 'Cancel' : '取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(english ? 'Clear' : '清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<McpConsoleViewModel>().clearActivities();
    }
  }
}

String _activityOutcomeLabel(McpActivityOutcome outcome, bool english) =>
    switch (outcome) {
      McpActivityOutcome.success => english ? 'Success' : '成功',
      McpActivityOutcome.denied => english ? 'Denied' : '已拒绝',
      McpActivityOutcome.failed => english ? 'Failed' : '失败',
    };

IconData _activityIcon(McpActivityKind kind) => switch (kind) {
  McpActivityKind.lifecycle => Icons.power_settings_new_rounded,
  McpActivityKind.protocol => Icons.swap_horiz_rounded,
  McpActivityKind.tool => Icons.handyman_outlined,
  McpActivityKind.security => Icons.security_outlined,
};

String _formatActivityDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}'
    ':${value.minute.toString().padLeft(2, '0')}'
    ':${value.second.toString().padLeft(2, '0')}';
