import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import '../../../services/mcp/mcp_invocation_policy.dart';
import '../../../services/mcp/mcp_server_controller.dart';
import '../../../services/mcp/mcp_server_settings.dart';
import '../../../services/mcp/mcp_tool_exposure_policy.dart';
import '../../../widgets/app_surface.dart';
import 'mcp_approval_queue_screen.dart';
import 'mcp_activity_screen.dart';
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
          Badge(
            isLabelVisible: viewModel.approvals.isNotEmpty,
            label: Text('${viewModel.approvals.length}'),
            child: IconButton(
              tooltip: english ? 'Approval queue' : '审批队列',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChangeNotifierProvider.value(
                    value: viewModel,
                    child: const McpApprovalQueueScreen(),
                  ),
                ),
              ),
              icon: const Icon(Icons.pending_actions_rounded),
            ),
          ),
          IconButton(
            key: const ValueKey('mcp-open-activity'),
            tooltip: english ? 'Recent activity' : '最近活动',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider.value(
                  value: viewModel,
                  child: const McpActivityScreen(),
                ),
              ),
            ),
            icon: const Icon(Icons.history_rounded),
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
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: status),
                    const SizedBox(width: 12),
                    Expanded(child: endpoint),
                  ],
                ),
              )
            else ...[
              status,
              const SizedBox(height: 12),
              endpoint,
            ],
            const SizedBox(height: 12),
            _ToolsCard(viewModel: viewModel, english: english),
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
      key: const ValueKey('mcp-server-status-card'),
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
      key: const ValueKey('mcp-client-configuration-card'),
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
    final strings = AppStrings(viewModel.language);
    final reviewMode =
        viewModel.approvalMode == McpApprovalMode.reviewConfiguredTools;
    return AppSectionCard(
      title: strings.mcpToolPolicyTitle,
      subtitle: strings.mcpToolPolicyHint,
      child: viewModel.tools.isEmpty
          ? Text(strings.mcpNoConfigurableTools)
          : Column(
              children: [
                for (final tool in viewModel.tools)
                  _ToolPolicyRow(
                    tool: tool,
                    strings: strings,
                    reviewMode: reviewMode,
                    onExposureChanged: (enabled) => unawaited(
                      viewModel.setToolExposure(tool.name, enabled),
                    ),
                    onReviewChanged: (enabled) => unawaited(
                      viewModel.setToolSecondaryReview(tool.name, enabled),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ToolPolicyRow extends StatelessWidget {
  final McpToolPolicySnapshot tool;
  final AppStrings strings;
  final bool reviewMode;
  final ValueChanged<bool> onExposureChanged;
  final ValueChanged<bool> onReviewChanged;

  const _ToolPolicyRow({
    required this.tool,
    required this.strings,
    required this.reviewMode,
    required this.onExposureChanged,
    required this.onReviewChanged,
  });

  @override
  Widget build(BuildContext context) {
    final exposed = tool.exposureResult == McpToolPolicyResult.exposed;
    final details = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            tool.destructive
                ? Icons.warning_amber_rounded
                : tool.readOnly
                ? Icons.visibility_outlined
                : Icons.build_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tool.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(tool.descriptionFor(strings.isEnglish)),
              const SizedBox(height: 5),
              _PolicyChip(
                exposureResult: tool.exposureResult,
                invocationAction: tool.invocationAction,
                reason: tool.reason,
                strings: strings,
              ),
              if (!tool.exposureConfigurable &&
                  tool.exposureResult != McpToolPolicyResult.exposed) ...[
                const SizedBox(height: 3),
                Text(
                  strings.mcpHardBoundaryHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final controls = Wrap(
      spacing: 10,
      runSpacing: 4,
      children: [
        _ToolCheckbox(
          key: ValueKey('mcp-exposure-${tool.name}'),
          label: strings.mcpExposeExternally,
          value: exposed,
          enabled: tool.exposureConfigurable,
          onChanged: onExposureChanged,
        ),
        if (reviewMode && tool.reviewEligible)
          _ToolCheckbox(
            key: ValueKey('mcp-review-${tool.name}'),
            label: strings.mcpSecondaryReview,
            value: tool.reviewSelected,
            enabled: exposed && tool.exposureConfigurable,
            onChanged: onReviewChanged,
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 16),
                    controls,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    details,
                    const SizedBox(height: 5),
                    Align(alignment: Alignment.centerRight, child: controls),
                  ],
                ),
        );
      },
    );
  }
}

class _ToolCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ToolCheckbox({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: label,
      checked: value,
      enabled: enabled,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            onChanged: enabled
                ? (next) {
                    if (next != null) onChanged(next);
                  }
                : null,
          ),
          Flexible(child: Text(label)),
        ],
      ),
    );
  }
}

class _PolicyChip extends StatelessWidget {
  final McpToolPolicyResult exposureResult;
  final McpInvocationAction invocationAction;
  final String reason;
  final AppStrings strings;

  const _PolicyChip({
    required this.exposureResult,
    required this.invocationAction,
    required this.reason,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    final label = switch (exposureResult) {
      McpToolPolicyResult.exposed => switch (invocationAction) {
        McpInvocationAction.execute => strings.mcpExecutable,
        McpInvocationAction.secondaryApproval => strings.mcpSecondaryReview,
        McpInvocationAction.denied => strings.mcpReviewRequired,
      },
      McpToolPolicyResult.hidden =>
        reason == 'not_exposed_by_user'
            ? strings.mcpNotExposed
            : strings.mcpHidden,
      McpToolPolicyResult.blocked => strings.mcpBlocked,
    };
    return Chip(label: Text(label, style: const TextStyle(fontSize: 11)));
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

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
