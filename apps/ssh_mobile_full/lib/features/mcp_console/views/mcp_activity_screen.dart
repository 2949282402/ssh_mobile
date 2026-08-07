import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import '../../../services/mcp/mcp_activity.dart';
import 'package:app_ui/app_ui.dart';
import '../viewmodels/mcp_console_viewmodel.dart';

class McpActivityScreen extends StatelessWidget {
  const McpActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<McpConsoleViewModel>();
    final strings = AppStrings(viewModel.language);
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
                        title: strings.mcpRecentActivity,
                        subtitle: strings.mcpActivitySubtitle,
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
                    _ActivityCard(viewModel: viewModel, strings: strings),
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
  final AppStrings strings;

  const _ActivityCard({required this.viewModel, required this.strings});

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      key: const ValueKey('mcp-recent-activity-card'),
      title: strings.mcpRecentActivity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(strings.mcpActivityAll),
                selected: viewModel.selectedOutcome == null,
                onSelected: (_) => viewModel.setSelectedOutcome(null),
              ),
              for (final outcome in McpActivityOutcome.values)
                ChoiceChip(
                  label: Text(_activityOutcomeLabel(outcome, strings)),
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
              label: Text(strings.mcpActivityClear),
            ),
          ),
          if (viewModel.activities.isEmpty)
            Text(strings.mcpActivityEmpty)
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
                    _activityOutcomeLabel(entry.outcome, strings),
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
        title: Text(strings.mcpActivityClearTitle),
        content: Text(strings.mcpActivityClearMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.clear),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<McpConsoleViewModel>().clearActivities();
    }
  }
}

String _activityOutcomeLabel(McpActivityOutcome outcome, AppStrings strings) =>
    switch (outcome) {
      McpActivityOutcome.success => strings.mcpActivitySuccess,
      McpActivityOutcome.denied => strings.mcpActivityDenied,
      McpActivityOutcome.failed => strings.mcpActivityFailed,
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
