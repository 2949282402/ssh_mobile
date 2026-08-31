part of '../llm_chat_screen.dart';

class ToolApprovalPanel extends StatelessWidget {
  final PendingToolApproval pending;
  final AiStrings strings;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const ToolApprovalPanel({
    super.key,
    required this.pending,
    required this.strings,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final en = strings.language == AppLanguage.en;
    final isBudgetAudit = pending.request.approvalType == 'budget_audit';
    final isAgentLoopBudget =
        pending.request.approvalType == 'agent_loop_round_budget';
    final title = switch (pending.request.approvalType) {
      'remote_delete' => en ? 'Approve remote delete' : '确认远端删除操作',
      'server_metadata_change' =>
        en ? 'Approve server metadata change' : '确认服务器元数据修改',
      'monitor_state_change' =>
        en ? 'Approve monitor state change' : '确认监控状态变更',
      'ssh_session_change' => en ? 'Approve SSH session change' : '确认 SSH 会话变更',
      'terminal_history_change' =>
        en ? 'Approve terminal history change' : '确认终端历史变更',
      'local_import' => en ? 'Approve local import' : '确认本地导入操作',
      'local_skill_change' => en ? 'Approve local skill change' : '确认本地技能变更',
      'local_log_change' => en ? 'Approve local log change' : '确认本地日志变更',
      'app_setting_change' => en ? 'Approve app settings change' : '确认应用设置变更',
      'budget_audit' => strings.budgetAuditTitle,
      'agent_loop_round_budget' =>
        en ? 'Extend agent loop rounds' : '延长 Agent 循环轮次',
      _ => en ? 'Approve tool action' : '确认工具操作',
    };
    final description = isBudgetAudit
        ? strings.budgetAuditReason
        : (isAgentLoopBudget
              ? (en
                    ? '${pending.request.reason} Tool call budget and safety approvals remain unchanged.'
                    : '${pending.request.reason} 工具调用预算与安全审批保持不变。')
              : (en
                    ? 'The model wants to perform this action on ${pending.request.connectionName}. Reason: ${pending.request.reason}'
                    : '模型想在 ${pending.request.connectionName} 上执行该操作。原因：${pending.request.reason}'));
    final reject = isAgentLoopBudget
        ? (en ? 'Pause' : '暂停')
        : (en ? 'Reject' : '拒绝');
    final approve = isAgentLoopBudget
        ? (en ? 'Continue' : '继续')
        : (en ? 'Approve' : '同意');
    final targetLabel = en ? 'Target' : '目标';
    final pathLabel = en ? 'Path' : '路径';
    final bytesLabel = en ? 'Bytes' : '字节';
    final commandLabel = en ? 'Command' : '命令';
    final previewLabel = en ? 'Preview' : '预览';
    final destructiveLabel = en ? 'This action is destructive.' : '这是一个破坏性操作。';
    final preview = pending.request.contentPreview?.trim();

    Widget metaBlock(String label, String value) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(
            value,
            style: TextStyle(color: colorScheme.onSurface, height: 1.35),
          ),
        ],
      );
    }

    Widget codeBlock(String value, {required double surfaceAlpha}) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: surfaceAlpha),
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: SelectableText(
          value,
          style: TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: const [
              'Consolas',
              'Microsoft YaHei',
              'PingFang SC',
              'sans-serif',
            ],
            color: colorScheme.onSurface,
            height: 1.4,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.42)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(
                  Icons.security_rounded,
                  size: 20,
                  color: colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colorScheme.error.withValues(alpha: 0.2)),
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              key: const ValueKey<String>('tool-approval-details'),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description,
                    key: const ValueKey<String>('tool-approval-description'),
                    style: TextStyle(
                      color: colorScheme.onSurface.withValues(alpha: 0.78),
                      height: 1.4,
                    ),
                  ),
                  if (pending.request.destructive) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 18,
                            color: colorScheme.error,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              destructiveLabel,
                              style: TextStyle(
                                color: colorScheme.error,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (!isBudgetAudit && !isAgentLoopBudget) ...[
                    const SizedBox(height: 12),
                    metaBlock(targetLabel, pending.request.connectionName),
                  ],
                  if (pending.request.targetPath != null) ...[
                    const SizedBox(height: 12),
                    metaBlock(pathLabel, pending.request.targetPath!),
                  ],
                  if (pending.request.byteLength != null) ...[
                    const SizedBox(height: 12),
                    metaBlock(bytesLabel, '${pending.request.byteLength}'),
                  ],
                  if (!isBudgetAudit && !isAgentLoopBudget) ...[
                    const SizedBox(height: 12),
                    Text(
                      commandLabel,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    codeBlock(pending.request.command, surfaceAlpha: 0.78),
                  ],
                  if (preview != null && preview.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      previewLabel,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    codeBlock(preview, surfaceAlpha: 0.62),
                  ],
                ],
              ),
            ),
          ),
          Divider(height: 1, color: colorScheme.error.withValues(alpha: 0.2)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey<String>('tool-approval-reject'),
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.close_rounded),
                    label: Text(reject),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey<String>('tool-approval-approve'),
                    onPressed: onApprove,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.check_rounded),
                    label: Text(approve),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
