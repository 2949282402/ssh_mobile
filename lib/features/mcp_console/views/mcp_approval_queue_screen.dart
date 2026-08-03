import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/mcp/mcp_approval_queue.dart';
import '../../../widgets/app_surface.dart';
import '../viewmodels/mcp_console_viewmodel.dart';

class McpApprovalQueueScreen extends StatelessWidget {
  const McpApprovalQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<McpConsoleViewModel>();
    final english = viewModel.isEnglish;
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
                        title: english ? 'MCP approvals' : 'MCP 审批队列',
                        subtitle: english
                            ? 'Review external MCP actions before execution'
                            : '执行外部 MCP 操作前进行审核',
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
                    ? _EmptyApprovals(english: english)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: approvals.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) => _ApprovalCard(
                          approval: approvals[index],
                          english: english,
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
  final bool english;

  const _EmptyApprovals({required this.english});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppEmptyState(
        icon: Icons.verified_user_outlined,
        title: english ? 'No pending approvals' : '暂无待审批操作',
        message: english
            ? 'Write-capable MCP calls will appear here before they run.'
            : '需要写入或改变状态的 MCP 请求会在执行前显示在这里。',
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  final McpApprovalSnapshot approval;
  final bool english;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _ApprovalCard({
    required this.approval,
    required this.english,
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
            label: english ? 'Target' : '目标',
            value: request.connectionName,
          ),
          _Meta(label: english ? 'Reason' : '原因', value: request.reason),
          _Meta(
            label: english ? 'Requested' : '请求时间',
            value: _formatDate(approval.createdAt),
          ),
          if (request.targetPath != null)
            _Meta(label: english ? 'Path' : '路径', value: request.targetPath!),
          if (request.byteLength != null)
            _Meta(
              label: english ? 'Bytes' : '字节',
              value: '${request.byteLength}',
            ),
          const SizedBox(height: 10),
          _CodeBlock(label: english ? 'Command' : '命令', value: request.command),
          if (request.contentPreview?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 10),
            _CodeBlock(
              label: english ? 'Preview' : '预览',
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
                    label: Text(english ? 'Reject' : '拒绝'),
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
                    label: Text(english ? 'Approve' : '批准'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _statusLabel(bool processing) {
    if (processing) return english ? 'Executing…' : '执行中…';
    return english ? 'Waiting for review' : '等待审核';
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
