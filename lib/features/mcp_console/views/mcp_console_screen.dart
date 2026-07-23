import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/mcp/mcp_activity.dart';
import '../../../services/mcp/mcp_server_controller.dart';
import '../../../services/mcp/mcp_tool_exposure_policy.dart';
import '../../../widgets/app_surface.dart';
import '../viewmodels/mcp_console_viewmodel.dart';

class McpConsoleScreen extends StatelessWidget {
  const McpConsoleScreen({super.key});

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
              _Header(viewModel: viewModel, english: english),
              if (viewModel.errorCode != null)
                _ErrorBanner(english: english, code: viewModel.errorCode!),
              Expanded(
                child: viewModel.loading
                    ? const Center(child: CircularProgressIndicator())
                    : _ConsoleBody(viewModel: viewModel, english: english),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final McpConsoleViewModel viewModel;
  final bool english;

  const _Header({required this.viewModel, required this.english});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Row(
        children: [
          if (Navigator.canPop(context))
            IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.maybePop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          Expanded(
            child: AppPageHeader(
              title: english ? 'Local MCP Console' : '本地 MCP 控制台',
              subtitle: english
                  ? 'Desktop diagnostics and safe observability'
                  : '桌面诊断与安全可观测性',
              icon: Icons.hub_outlined,
            ),
          ),
          IconButton(
            tooltip: english ? 'Refresh' : '刷新',
            onPressed: viewModel.runningAction ? null : viewModel.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final bool english;
  final String code;

  const _ErrorBanner({required this.english, required this.code});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        english ? 'Operation failed: $code' : '操作失败：$code',
        style: TextStyle(color: colors.onErrorContainer),
      ),
    );
  }
}

class _ConsoleBody extends StatelessWidget {
  final McpConsoleViewModel viewModel;
  final bool english;

  const _ConsoleBody({required this.viewModel, required this.english});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final status = _StatusCard(viewModel: viewModel, english: english);
        final endpoint = _EndpointCard(viewModel: viewModel, english: english);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: status),
                  const SizedBox(width: 12),
                  Expanded(child: endpoint),
                ],
              )
            else ...[
              status,
              const SizedBox(height: 12),
              endpoint,
            ],
            const SizedBox(height: 12),
            _ToolsCard(viewModel: viewModel, english: english),
            const SizedBox(height: 12),
            _ActivityCard(viewModel: viewModel, english: english),
          ],
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  final McpConsoleViewModel viewModel;
  final bool english;

  const _StatusCard({required this.viewModel, required this.english});

  @override
  Widget build(BuildContext context) {
    final snapshot = viewModel.status;
    final colors = Theme.of(context).colorScheme;
    final running = snapshot.running;
    final color = running ? Colors.green : colors.outline;
    return AppSectionCard(
      title: english ? 'Server status' : '服务器状态',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 12, color: color),
              const SizedBox(width: 8),
              Text(
                _statusLabel(snapshot.status, english),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                snapshot.enabled
                    ? (english ? 'Enabled' : '已启用')
                    : (english ? 'Disabled' : '已禁用'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('${english ? 'Endpoint' : '端点'}: ${snapshot.url}'),
          if (snapshot.startedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              '${english ? 'Started' : '启动时间'}: ${_formatDate(snapshot.startedAt!)}',
            ),
          ],
          if (snapshot.lastError != null) ...[
            const SizedBox(height: 6),
            Text(snapshot.lastError!, style: TextStyle(color: colors.error)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: viewModel.runningAction || running
                    ? null
                    : viewModel.start,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(english ? 'Start' : '启动'),
              ),
              OutlinedButton.icon(
                onPressed: viewModel.runningAction || !running
                    ? null
                    : viewModel.stop,
                icon: const Icon(Icons.stop_rounded),
                label: Text(english ? 'Stop' : '停止'),
              ),
              OutlinedButton.icon(
                onPressed: viewModel.runningAction ? null : viewModel.restart,
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(english ? 'Restart' : '重启'),
              ),
              OutlinedButton.icon(
                onPressed: viewModel.runningAction ? null : viewModel.checkPort,
                icon: const Icon(Icons.network_check_rounded),
                label: Text(english ? 'Check port' : '检查端口'),
              ),
              OutlinedButton.icon(
                onPressed: viewModel.runningAction
                    ? null
                    : viewModel.runSelfTest,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(english ? 'Self-test' : '完整自检'),
              ),
            ],
          ),
          if (viewModel.lastSelfTest != null) ...[
            const SizedBox(height: 10),
            Text(_selfTestLabel(viewModel.lastSelfTest!, english)),
          ],
        ],
      ),
    );
  }
}

class _EndpointCard extends StatelessWidget {
  final McpConsoleViewModel viewModel;
  final bool english;

  const _EndpointCard({required this.viewModel, required this.english});

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      title: english ? 'Client configuration' : '客户端配置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${english ? 'Token' : 'Token'}: ${viewModel.maskedToken}'),
          const SizedBox(height: 4),
          Text(
            english
                ? 'The token is never displayed or recorded. Copy is explicit.'
                : 'Token 不会展示或记录；配置复制必须由用户主动触发。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _CopyButton(label: 'Codex', text: viewModel.codexConfig),
              _CopyButton(label: 'Claude Code', text: viewModel.claudeConfig),
              _CopyButton(label: 'Gemini CLI', text: viewModel.geminiConfig),
            ],
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final String label;
  final String text;

  const _CopyButton({required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.copy_rounded, size: 16),
      label: Text(label),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$label ${Localizations.localeOf(context).languageCode == 'en' ? 'configuration copied' : '配置已复制'}',
            ),
          ),
        );
      },
    );
  }
}

class _ToolsCard extends StatelessWidget {
  final McpConsoleViewModel viewModel;
  final bool english;

  const _ToolsCard({required this.viewModel, required this.english});

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      title: english ? 'Tool exposure' : '工具暴露策略',
      child: viewModel.tools.isEmpty
          ? Text(english ? 'No tools available.' : '没有可用工具。')
          : Column(
              children: [
                for (final tool in viewModel.tools)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      tool.destructive
                          ? Icons.warning_amber_rounded
                          : tool.readOnly
                          ? Icons.visibility_outlined
                          : Icons.build_outlined,
                    ),
                    title: Text(tool.name),
                    subtitle: Text(tool.reason),
                    trailing: _PolicyChip(
                      result: tool.result,
                      english: english,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _PolicyChip extends StatelessWidget {
  final McpToolPolicyResult result;
  final bool english;

  const _PolicyChip({required this.result, required this.english});

  @override
  Widget build(BuildContext context) {
    final label = switch (result) {
      McpToolPolicyResult.exposed => english ? 'Executable' : '可执行',
      McpToolPolicyResult.approvalRequired =>
        english ? 'Approval required' : '需要审批',
      McpToolPolicyResult.hidden => english ? 'Hidden' : '隐藏',
      McpToolPolicyResult.blocked => english ? 'Blocked' : '已阻断',
    };
    return Chip(label: Text(label, style: const TextStyle(fontSize: 11)));
  }
}

class _ActivityCard extends StatelessWidget {
  final McpConsoleViewModel viewModel;
  final bool english;

  const _ActivityCard({required this.viewModel, required this.english});

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      title: english ? 'Recent activity' : '最近活动',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(english ? 'All' : '全部'),
                selected: viewModel.selectedOutcome == null,
                onSelected: (_) => viewModel.setSelectedOutcome(null),
              ),
              for (final outcome in McpActivityOutcome.values)
                ChoiceChip(
                  label: Text(_outcomeLabel(outcome, english)),
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
                    _formatDate(entry.occurredAt),
                    _outcomeLabel(entry.outcome, english),
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

String _statusLabel(McpServerRunStatus status, bool english) =>
    switch (status) {
      McpServerRunStatus.running => english ? 'Running' : '运行中',
      McpServerRunStatus.stopped => english ? 'Stopped' : '已停止',
      McpServerRunStatus.starting => english ? 'Starting' : '正在启动',
      McpServerRunStatus.checkingPort => english ? 'Checking port' : '正在检查端口',
      McpServerRunStatus.failed => english ? 'Failed' : '失败',
    };

String _selfTestLabel(McpSelfTestResult result, bool english) =>
    result.succeeded
    ? (english
          ? 'Self-test passed (${result.durationMs} ms)'
          : '自检通过（${result.durationMs} ms）')
    : (english
          ? 'Self-test failed: ${result.failureCode}'
          : '自检失败：${result.failureCode}');

String _outcomeLabel(McpActivityOutcome outcome, bool english) =>
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

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
