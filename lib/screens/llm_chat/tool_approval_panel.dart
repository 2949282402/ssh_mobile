part of '../llm_chat_screen.dart';

class _ToolApprovalPanel extends StatelessWidget {
  final PendingToolApproval pending;
  final _AiStrings strings;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _ToolApprovalPanel({
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
      _ => en ? 'Approve tool action' : '确认工具操作',
    };
    final description = isBudgetAudit
        ? strings.budgetAuditReason
        : (en
            ? 'The model wants to perform this action on ${pending.request.connectionName}. Reason: ${pending.request.reason}'
            : '模型想在 ${pending.request.connectionName} 上执行该操作。原因：${pending.request.reason}');
    final reject = en ? 'Reject' : '拒绝';
    final approve = en ? 'Approve' : '同意';
    final maxCommandHeight =
        (MediaQuery.sizeOf(context).height * 0.24).clamp(96.0, 180.0);
    final targetLabel = en ? 'Target' : '目标';
    final pathLabel = en ? 'Path' : '路径';
    final bytesLabel = en ? 'Bytes' : '字节';
    final previewLabel = en ? 'Preview' : '预览';
    final destructiveLabel = en ? 'This action is destructive.' : '这是一个破坏性操作。';
    final preview = pending.request.contentPreview?.trim();

    Widget metaRow(String label, String value) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OverflowScrollText(
              value,
              selectable: true,
              maxLines: 1,
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.42)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.72),
              height: 1.35,
            ),
          ),
          if (pending.request.destructive) ...[
            const SizedBox(height: 8),
            Text(
              destructiveLabel,
              style: TextStyle(
                color: colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (!isBudgetAudit) ...[
            metaRow(targetLabel, pending.request.connectionName),
            const SizedBox(height: 8),
          ],
          if (pending.request.targetPath != null) ...[
            metaRow(pathLabel, pending.request.targetPath!),
            const SizedBox(height: 8),
          ],
          if (pending.request.byteLength != null) ...[
            metaRow(bytesLabel, '${pending.request.byteLength}'),
            const SizedBox(height: 8),
          ],
          if (!isBudgetAudit)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxCommandHeight),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.surface.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        pending.request.command,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (preview != null && preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              previewLabel,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SelectableText(
                    preview,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onReject,
                icon: const Icon(Icons.close_rounded),
                label: Text(reject),
              ),
              FilledButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check_rounded),
                label: Text(approve),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
