import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import '../../../services/mcp/mcp_approval_queue.dart';
import '../../../widgets/app_surface.dart';
import '../viewmodels/mcp_console_viewmodel.dart';

class McpApprovalQueueScreen extends StatelessWidget {
  const McpApprovalQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<McpConsoleViewModel>();
    final strings = AppStrings(viewModel.language);
    final approvals = viewModel.approvals;
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
                        title: strings.mcpApprovalQueueTitle,
                        subtitle: strings.mcpApprovalQueueSubtitle,
                        icon: Icons.pending_actions_rounded,
                      ),
                    ),
                    Chip(
                      label: Text('${approvals.length}'),
                      avatar: const Icon(Icons.pending_actions_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: approvals.isEmpty
                    ? _EmptyApprovals(strings: strings)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: approvals.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) => _ApprovalCard(
                          approval: approvals[index],
                          strings: strings,
                          onApprove: () =>
                              viewModel.approve(approvals[index].id),
                          onReject: () => viewModel.reject(approvals[index].id),
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

class _EmptyApprovals extends StatelessWidget {
  final AppStrings strings;

  const _EmptyApprovals({required this.strings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppEmptyState(
        icon: Icons.verified_user_outlined,
        title: strings.mcpNoPendingApprovals,
        message: strings.mcpApprovalQueueEmptyMessage,
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  final McpApprovalSnapshot approval;
  final AppStrings strings;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _ApprovalCard({
    required this.approval,
    required this.strings,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final request = approval.request;
    final processing = approval.state == McpApprovalState.processing;
    return AppSectionCard(
      title: request.toolName,
      subtitle: _statusLabel(processing),
      trailing: request.destructive
          ? const Icon(Icons.warning_amber_rounded, color: Colors.red)
          : const Icon(Icons.security_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Meta(
            label: strings.mcpApprovalTarget,
            value: request.connectionName,
          ),
          _Meta(label: strings.mcpApprovalReason, value: request.reason),
          _Meta(
            label: strings.mcpApprovalRequested,
            value: _formatDate(approval.createdAt),
          ),
          if (request.targetPath != null)
            _Meta(label: strings.mcpApprovalPath, value: request.targetPath!),
          if (request.byteLength != null)
            _Meta(
              label: strings.mcpApprovalBytes,
              value: '${request.byteLength}',
            ),
          const SizedBox(height: 10),
          _CodeBlock(label: strings.mcpApprovalCommand, value: request.command),
          if (request.contentPreview?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 10),
            _CodeBlock(
              label: strings.mcpApprovalPreview,
              value: request.contentPreview!.trim(),
            ),
          ],
          const SizedBox(height: 12),
          if (processing)
            const LinearProgressIndicator(minHeight: 3)
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.close_rounded),
                    label: Text(strings.reject),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onApprove,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.check_rounded),
                    label: Text(strings.mcpApprovalApprove),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _statusLabel(bool processing) {
    if (processing) return strings.mcpApprovalExecuting;
    return strings.mcpApprovalWaiting;
  }
}

class _Meta extends StatelessWidget {
  final String label;
  final String value;

  const _Meta({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final String label;
  final String value;

  const _CodeBlock({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace', height: 1.4),
          ),
        ),
      ],
    );
  }
}

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}:'
    '${value.second.toString().padLeft(2, '0')}';
