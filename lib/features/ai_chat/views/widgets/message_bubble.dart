import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/agent/plan_execution_controller.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/features/ai_chat/pages/agent_trace_debug_page.dart';
import 'trace_panel.dart';
import 'message_attachments_wrap.dart';

import '../llm_chat_screen.dart'; // For AiStrings/AiStrings extensions

class MessageBubble extends StatelessWidget {
  final String chatId;
  final int index;
  final AiChatMessageRecord message;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;
  final bool canAct;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;
  final VoidCallback? onContinueTimeout;
  final VoidCallback? onApproveExecute;
  final VoidCallback? onRevisePlan;

  const MessageBubble({
    super.key,
    required this.chatId,
    required this.index,
    required this.message,
    this.streamingTextListenable,
    this.streamingStatusListenable,
    this.canAct = false,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
    this.onContinueTimeout,
    this.onApproveExecute,
    this.onRevisePlan,
  });

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiChatViewModel>();
    final activeChat = viewModel.activeChat;
    final isLatestAssistant = activeChat != null &&
        activeChat.messages.lastIndexWhere((m) => m.role == 'assistant') ==
            index;

    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);

    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final isError = message.role == 'error';
    final isAssistant = !isUser && !isError;
    final canCopyAssistant = isAssistant && message.text.trim().isNotEmpty;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isUser && !isError && message.traces.isNotEmpty)
              TracePanel(
                traces: message.traces,
                storageKey:
                    'trace-panel-${message.createdAt.microsecondsSinceEpoch}',
              ),
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isError
                    ? colorScheme.error.withValues(alpha: 0.08)
                    : isUser
                        ? colorScheme.primary.withValues(alpha: 0.14)
                        : colorScheme.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(AppTheme.radiusMedium),
                  topRight: isUser
                      ? const Radius.circular(4)
                      : const Radius.circular(AppTheme.radiusMedium),
                  bottomLeft: const Radius.circular(AppTheme.radiusMedium),
                  bottomRight: isUser
                      ? const Radius.circular(AppTheme.radiusMedium)
                      : const Radius.circular(4),
                ),
                border: Border.all(
                  color: isError
                      ? colorScheme.error.withValues(alpha: 0.3)
                      : isUser
                          ? colorScheme.primary.withValues(alpha: 0.2)
                          : colorScheme.outlineVariant,
                ),
              ),
              child: isUser || isError
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isUser && message.attachments.isNotEmpty)
                          MessageAttachmentsWrap(
                              attachments: message.attachments),
                        SelectableText(
                          message.text.isEmpty ? '...' : message.text,
                          style: TextStyle(
                            color: isError
                                ? colorScheme.error
                                : colorScheme.onSurface,
                            height: 1.35,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AssistantMarkdownBody(
                          text: message.text,
                          streamingTextListenable: streamingTextListenable,
                          streamingStatusListenable: streamingStatusListenable,
                        ),
                        if (message.todoSteps.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _ChatTodoPanel(
                            chatId: chatId,
                            message: message,
                            onRevisePlan: onRevisePlan,
                          ),
                          if (message.todoSteps.every(
                                  (s) => s.status == StepStatus.pending) &&
                              isLatestAssistant) ...[
                            const SizedBox(height: 8),
                            _buildApproveButton(context),
                            const SizedBox(height: 4),
                            Center(
                              child: Text(
                                strings.language == AppLanguage.en
                                    ? '💡 If you want to modify this plan, simply type your feedback to adjust it.'
                                    : '💡 如果你想修改此计划，直接在下方输入框发送修改意见以进行调整。',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontStyle: FontStyle.italic,
                                  color: colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                            ),
                          ],
                        ]
                      ],
                    ),
            ),
            if (!isUser && message.agentRunId?.trim().isNotEmpty == true)
              _AgentRunInlineSummary(
                runId: message.agentRunId!.trim(),
              ),
            if (!isUser && message.agentRunId?.trim().isNotEmpty == true)
              _AgentTraceLink(
                chatId: chatId,
                runId: message.agentRunId!.trim(),
                message: message,
              ),
            if (canAct &&
                (onEditUser != null ||
                    onRegenerate != null ||
                    onBranch != null ||
                    onContinueTimeout != null ||
                    canCopyAssistant))
              _MessageActions(
                isUser: isUser,
                isError: isError,
                assistantText: isAssistant ? message.text : null,
                onEditUser: onEditUser,
                onRegenerate: onRegenerate,
                onBranch: onBranch,
                onContinueTimeout: onContinueTimeout,
              ),
            if (!isUser && !isError && message.totalTokens != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  _messageStats(message),
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
                    height: 1.2,
                  ),
                ),
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    )
        .animate(
          key: ValueKey(
              'msg-animate-${message.createdAt.microsecondsSinceEpoch}'),
        )
        .fade(duration: 200.ms)
        .slideX(
          begin: isUser ? 0.05 : -0.05,
          end: 0,
          duration: 200.ms,
          curve: Curves.easeOutQuad,
        );
  }

  Widget _buildApproveButton(BuildContext context) {
    final settings = context.read<AppSettings>();
    final strings = AiStrings(settings.language);
    final theme = Theme.of(context);
    final extColors = theme.extension<ExtendedColors>();

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: FilledButton.icon(
          onPressed: onApproveExecute,
          icon: const Icon(Icons.verified_user_outlined, size: 16),
          label: Text(
            strings.approveAndExecutePlan,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: extColors?.success ?? theme.colorScheme.primary,
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
          ),
        ),
      ),
    );
  }

  String _messageStats(AiChatMessageRecord message) {
    final parts = <String>[];
    if (message.totalTokens != null) {
      parts.add(
        '${message.tokenUsageEstimated == true ? 'est.' : 'API'} tokens ${message.totalTokens}',
      );
    }
    if (message.promptTokens != null || message.completionTokens != null) {
      parts.add(
        'in ${message.promptTokens ?? '-'} / out ${message.completionTokens ?? '-'}',
      );
    }
    if (message.elapsedMs != null) {
      parts.add('time ${_formatElapsed(message.elapsedMs!)}');
    }
    if (message.promptCacheHitTokens != null ||
        message.promptCacheMissTokens != null) {
      parts.add(
        'cache ${message.promptCacheHitTokens ?? 0}/${message.promptCacheMissTokens ?? 0}',
      );
    }
    if (message.reasoningTokens != null && message.reasoningTokens! > 0) {
      parts.add('reasoning ${message.reasoningTokens}');
    }
    return parts.join(' · ');
  }

  String _formatElapsed(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}

class _AgentRunInlineSummary extends StatefulWidget {
  final String runId;

  const _AgentRunInlineSummary({
    required this.runId,
  });

  @override
  State<_AgentRunInlineSummary> createState() => _AgentRunInlineSummaryState();
}

class _AgentRunInlineSummaryState extends State<_AgentRunInlineSummary> {
  late Future<_AgentRunInlineData?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _AgentRunInlineSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runId != widget.runId) {
      _future = _load();
    }
  }

  Future<_AgentRunInlineData?> _load() async {
    final storage = context.read<StorageService>();
    final events = await storage.loadAgentTraceEvents(widget.runId);
    final metrics = await storage.loadAgentRunMetrics();
    AgentRunMetrics? metric;
    for (final item in metrics) {
      if (item.id == widget.runId) {
        metric = item;
        break;
      }
    }
    if (metric == null && events.isEmpty) return null;
    return _AgentRunInlineData.from(metric: metric, events: events);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AgentRunInlineData?>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final extColors = theme.extension<ExtendedColors>();
        final isEn = context.read<AppSettings>().language == AppLanguage.en;
        final statusColor = data.success
            ? (extColors?.success ?? colorScheme.primary)
            : colorScheme.error;
        return Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _RunSummaryChip(
                icon: data.success
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                label: data.success
                    ? (isEn ? 'Run completed' : '运行完成')
                    : (isEn ? 'Run needs attention' : '运行需处理'),
                color: statusColor,
              ),
              if (data.toolCalls > 0)
                _RunSummaryChip(
                  icon: Icons.build_outlined,
                  label: isEn
                      ? '${data.toolCalls} tools'
                      : '${data.toolCalls} 个工具',
                  color: colorScheme.primary,
                ),
              if (data.approvalCount > 0)
                _RunSummaryChip(
                  icon: Icons.verified_user_outlined,
                  label: isEn
                      ? '${data.approvedCount}/${data.approvalCount} approvals'
                      : '${data.approvedCount}/${data.approvalCount} 次审批',
                  color: colorScheme.tertiary,
                ),
              if (data.blockedCount > 0)
                _RunSummaryChip(
                  icon: Icons.block_outlined,
                  label: isEn
                      ? '${data.blockedCount} blocked'
                      : '${data.blockedCount} 次阻断',
                  color: colorScheme.error,
                ),
              if (data.elapsedMs != null)
                _RunSummaryChip(
                  icon: Icons.timer_outlined,
                  label: _formatRunElapsed(data.elapsedMs!),
                  color: colorScheme.onSurfaceVariant,
                ),
              if (data.finalOutcome != null)
                _RunSummaryChip(
                  icon: Icons.flag_outlined,
                  label: data.finalOutcome!,
                  color: colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        );
      },
    );
  }

  String _formatRunElapsed(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}

class _AgentRunInlineData {
  final bool success;
  final int toolCalls;
  final int approvalCount;
  final int approvedCount;
  final int blockedCount;
  final int? elapsedMs;
  final String? finalOutcome;

  const _AgentRunInlineData({
    required this.success,
    required this.toolCalls,
    required this.approvalCount,
    required this.approvedCount,
    required this.blockedCount,
    required this.elapsedMs,
    required this.finalOutcome,
  });

  factory _AgentRunInlineData.from({
    required AgentRunMetrics? metric,
    required List<AgentTraceEvent> events,
  }) {
    final blockedCount = events
        .where((event) =>
            event.kind.contains('blocked') ||
            event.status.contains('blocked') ||
            event.status.contains('rejected'))
        .length;
    final toolEvents = events
        .where((event) =>
            event.kind.contains('tool_result') ||
            event.kind.contains('tool_request'))
        .length;
    final approvalEvents =
        events.where((event) => event.kind.contains('approval')).length;
    final finalOutcome = _finalOutcomeFrom(events);
    final success = metric?.success ??
        (finalOutcome == null ||
            finalOutcome == 'success' ||
            finalOutcome == 'completed');

    return _AgentRunInlineData(
      success: success,
      toolCalls: metric?.toolCalls ?? toolEvents,
      approvalCount: metric?.approvalCount ?? approvalEvents,
      approvedCount: metric?.approvedCount ?? 0,
      blockedCount: blockedCount,
      elapsedMs: metric?.elapsedMs,
      finalOutcome: finalOutcome,
    );
  }

  static String? _finalOutcomeFrom(List<AgentTraceEvent> events) {
    for (final event in events.reversed) {
      if (event.kind != 'agent_run_summary') continue;
      try {
        final decoded = jsonDecode(event.content);
        if (decoded is Map) {
          final value = decoded['finalOutcome'] ?? decoded['outcome'];
          if (value is String && value.trim().isNotEmpty) {
            return value.trim();
          }
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

class _RunSummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _RunSummaryChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentTraceLink extends StatelessWidget {
  final String chatId;
  final String runId;
  final AiChatMessageRecord message;

  const _AgentTraceLink({
    required this.chatId,
    required this.runId,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final String label;
    if (message.traces.isNotEmpty) {
      final tools =
          message.traces.where((trace) => trace.kind.contains('tool')).length;
      final approvals = message.traces
          .where((trace) => trace.kind.contains('approval'))
          .length;
      final elapsed = message.elapsedMs == null
          ? null
          : _formatElapsedForTraceLink(message.elapsedMs!);
      label = [
        'Trace',
        '${message.traces.length} events',
        if (tools > 0) '$tools tools',
        if (approvals > 0) '$approvals approvals',
        if (elapsed != null) elapsed,
      ].join(' · ');
    } else {
      final shortRunId =
          runId.length > 8 ? runId.substring(runId.length - 8) : runId;
      label = 'Trace · $shortRunId';
    }

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AgentTraceDebugPage(
                chatId: chatId,
                runId: runId,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 14,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatElapsedForTraceLink(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}

class EditUserMessageDialog extends StatefulWidget {
  final String initialText;
  final AiStrings strings;

  const EditUserMessageDialog({
    super.key,
    required this.initialText,
    required this.strings,
  });

  @override
  State<EditUserMessageDialog> createState() => EditUserMessageDialogState();
}

class EditUserMessageDialogState extends State<EditUserMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.strings.editMessage),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.strings.saveAndSend),
        ),
      ],
    );
  }
}

class _AssistantMarkdownBody extends StatelessWidget {
  final String text;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;

  const _AssistantMarkdownBody({
    required this.text,
    this.streamingTextListenable,
    this.streamingStatusListenable,
  });

  String _cleanTextForMarkdown(String text, BuildContext context) {
    final isEn = context.read<AppSettings>().language == AppLanguage.en;
    return text.replaceAll(
      RegExp(r'```playbook\s*\{[\s\S]*?\}\s*```'),
      isEn
          ? '\n\n*📋 Operational plan steps generated below. Please select a target server first, then execute step-by-step:*'
          : '\n\n*📋 规划的运维步骤已在下方可视化生成，请先选择目标服务器后点击运行：*',
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = streamingTextListenable;
    if (listenable == null) {
      return _buildMarkdown(context, _cleanTextForMarkdown(text, context));
    }
    return ValueListenableBuilder<String>(
      valueListenable: listenable,
      builder: (context, value, _) => ValueListenableBuilder<String>(
        valueListenable: streamingStatusListenable ?? emptyStringListenable,
        builder: (context, status, _) {
          final displayText = value.isEmpty ? text : value;
          final hasText = displayText.trim().isNotEmpty;
          final label = status.trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (label.isNotEmpty || !hasText)
                AssistantRunIndicator(
                  label: label.isEmpty ? '...' : label,
                  compact: hasText,
                ),
              if (hasText)
                Padding(
                  padding: EdgeInsets.only(
                    top: label.isNotEmpty ? 8 : 0,
                  ),
                  child: _buildMarkdown(
                      context, _cleanTextForMarkdown(displayText, context)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMarkdown(BuildContext context, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return GptMarkdown(
      value.isEmpty ? '...' : value,
      style: TextStyle(
        color: colorScheme.onSurface,
        height: 1.35,
      ),
    );
  }
}

class _MessageActions extends StatelessWidget {
  final bool isUser;
  final bool isError;
  final String? assistantText;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;
  final VoidCallback? onContinueTimeout;

  const _MessageActions({
    required this.isUser,
    required this.isError,
    this.assistantText,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
    this.onContinueTimeout,
  });

  @override
  Widget build(BuildContext context) {
    final en = context.read<AppSettings>().language == AppLanguage.en;
    final colorScheme = Theme.of(context).colorScheme;
    final copyText =
        assistantText?.trim().isNotEmpty == true ? assistantText!.trim() : null;
    final children = <Widget>[
      if (copyText != null)
        _actionButton(
          context,
          tooltip: en ? 'Copy reply' : '复制回复',
          icon: Icons.content_copy_rounded,
          onPressed: () => _copyAssistantText(context, copyText, en),
        ),
      if (copyText != null)
        _actionButton(
          context,
          tooltip: en ? 'Select and copy' : '选择复制',
          icon: Icons.select_all_rounded,
          onPressed: () => _showSelectableCopySheet(context, copyText, en),
        ),
      if (onEditUser != null)
        _actionButton(
          context,
          tooltip: 'Edit and resend',
          icon: Icons.edit_outlined,
          onPressed: onEditUser,
        ),
      if (onRegenerate != null)
        _actionButton(
          context,
          tooltip: en ? 'Regenerate' : '重新生成',
          icon: Icons.refresh_rounded,
          onPressed: onRegenerate,
        ),
      if (onBranch != null)
        _actionButton(
          context,
          tooltip: en ? 'Create branch' : '创建分支',
          icon: Icons.call_split_rounded,
          onPressed: onBranch,
        ),
      if (onContinueTimeout != null)
        _actionButton(
          context,
          tooltip: 'Continue',
          icon: Icons.play_arrow_rounded,
          onPressed: onContinueTimeout,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, bottom: 4),
      child: Row(
        mainAxisAlignment: isUser && !isError
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color:
                  colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.72),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAssistantText(
    BuildContext context,
    String text,
    bool en,
  ) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(en ? 'Reply copied' : '已复制回复'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showSelectableCopySheet(
    BuildContext context,
    String text,
    bool en,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.78;
        return SafeArea(
          child: SizedBox(
            height: maxHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          en ? 'Select and copy' : '选择复制',
                          style: Theme.of(sheetContext)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: en ? 'Copy all' : '复制全文',
                        icon: const Icon(Icons.content_copy_rounded),
                        onPressed: () =>
                            _copyAssistantText(sheetContext, text, en),
                      ),
                      IconButton(
                        tooltip: en ? 'Close' : '关闭',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.36),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusSmall),
                        border: Border.all(
                          color: colorScheme.outlineVariant
                              .withValues(alpha: 0.72),
                        ),
                      ),
                      child: Scrollbar(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            text,
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              height: 1.38,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        iconSize: 17,
        color: colorScheme.onSurfaceVariant,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}

class _ChatTodoPanel extends StatefulWidget {
  final String chatId;
  final AiChatMessageRecord message;
  final VoidCallback? onRevisePlan;

  const _ChatTodoPanel({
    required this.chatId,
    required this.message,
    this.onRevisePlan,
  });

  @override
  State<_ChatTodoPanel> createState() => _ChatTodoPanelState();
}

class _ChatTodoPanelState extends State<_ChatTodoPanel> {
  final Set<int> _expandedIndices = {};

  String? _getServerDisplayName(BuildContext context, String? connectionId) {
    if (connectionId == null || connectionId.trim().isEmpty) return null;
    try {
      final viewModel = context.read<AiChatViewModel>();
      final conn = viewModel.getConnection(connectionId);
      return conn?.name ?? 'Server';
    } catch (_) {
      return 'Server';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEn = context.read<AppSettings>().language == AppLanguage.en;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.rule_folder_outlined,
                size: 18,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isEn ? 'Operation Tasks (TODO)' : '规划的运维任务清单 (TODO)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 12),
          for (var i = 0; i < widget.message.todoSteps.length; i++) ...[
            _buildStepRow(
                context, i, widget.message.todoSteps[i], colorScheme, isEn),
            if (i < widget.message.todoSteps.length - 1)
              const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildStepRow(
    BuildContext context,
    int index,
    AiTodoStep step,
    ColorScheme colorScheme,
    bool isEn,
  ) {
    final isExpanded = _expandedIndices.contains(index);
    final hasLogs =
        (step.stdout?.isNotEmpty == true || step.stderr?.isNotEmpty == true);

    final snapshot =
        const PlanExecutionController().snapshot(widget.message.todoSteps);
    final isCurrent = snapshot.currentStep?.id == step.id;
    final isFailed = step.status == StepStatus.failed;
    final isRunning = step.status == StepStatus.running;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedIndices.remove(index);
              } else {
                _expandedIndices.add(index);
              }
            });
          },
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          child: Container(
            decoration: BoxDecoration(
              color: isRunning
                  ? colorScheme.primary.withValues(alpha: 0.08)
                  : isFailed
                      ? colorScheme.error.withValues(alpha: 0.08)
                      : isCurrent && step.status == StepStatus.pending
                          ? colorScheme.secondaryContainer
                              .withValues(alpha: 0.3)
                          : null,
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              border: Border.all(
                color: isRunning
                    ? colorScheme.primary.withValues(alpha: 0.24)
                    : isFailed
                        ? colorScheme.error.withValues(alpha: 0.3)
                        : isCurrent && step.status == StepStatus.pending
                            ? colorScheme.secondary.withValues(alpha: 0.15)
                            : Colors.transparent,
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _buildStatusIcon(step.status, colorScheme),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: step.status == StepStatus.success
                              ? colorScheme.onSurface.withValues(alpha: 0.6)
                              : colorScheme.onSurface,
                          decoration: step.status == StepStatus.success
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      if (step.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            step.description,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (step.connectionId != null &&
                    _getServerDisplayName(context, step.connectionId) !=
                        null) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusSmall),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.dns_outlined,
                              size: 10, color: colorScheme.onSurfaceVariant),
                          const SizedBox(width: 2),
                          Text(
                            _getServerDisplayName(context, step.connectionId)!,
                            style: TextStyle(
                              fontSize: 9.5,
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 30, top: 4, right: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (step.command.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.48),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Text(
                      step.command,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontFamilyFallback: [
                          'Consolas',
                          'Microsoft YaHei',
                          'PingFang SC',
                          'sans-serif'
                        ],
                        fontSize: 10.5,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
                if (isFailed) ...[
                  const SizedBox(height: 6),
                  Text(
                    isEn
                        ? 'Review the logs, retry after fixing the cause, skip only when it is safe, or return to Plan Mode to revise the remaining steps.'
                        : '请先查看日志并修复原因后重试；仅在确认安全时跳过，也可以返回规划模式调整后续步骤。',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          context
                              .read<AiChatViewModel>()
                              .retryTodoStep(step.id);
                        },
                        icon: const Icon(Icons.refresh, size: 13),
                        label: Text(isEn ? 'Retry Step' : '重试此步骤'),
                        style: ElevatedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          textStyle: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final reasonController = TextEditingController();
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogCtx) => AlertDialog(
                              title: Text(isEn ? 'Skip Step' : '跳过步骤'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(isEn
                                      ? 'Provide a reason for skipping this task:'
                                      : '请输入跳过此任务的原因：'),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: reasonController,
                                    decoration: InputDecoration(
                                      hintText: isEn
                                          ? 'e.g. Completed manually'
                                          : '例如：已手动完成',
                                      border: const OutlineInputBorder(),
                                    ),
                                    autofocus: true,
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogCtx, false),
                                  child: Text(isEn ? 'Cancel' : '取消'),
                                ),
                                ElevatedButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogCtx, true),
                                  child: Text(isEn ? 'Skip' : '跳过'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true &&
                              reasonController.text.trim().isNotEmpty) {
                            if (context.mounted) {
                              context.read<AiChatViewModel>().skipTodoStep(
                                    step.id,
                                    reasonController.text.trim(),
                                  );
                            }
                          }
                        },
                        icon: const Icon(Icons.skip_next, size: 13),
                        label: Text(isEn ? 'Skip Step' : '跳过此步骤'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: widget.onRevisePlan,
                        icon: const Icon(Icons.edit_note_outlined, size: 13),
                        label: Text(isEn ? 'Revise Plan' : '调整计划'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
                if (hasLogs) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.84),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '${step.stdout ?? ''}\n${step.stderr ?? ''}'.trim(),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: [
                            'Consolas',
                            'Microsoft YaHei',
                            'PingFang SC',
                            'sans-serif'
                          ],
                          fontSize: 10,
                          color: Colors.greenAccent,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStatusIcon(StepStatus status, ColorScheme colorScheme) {
    switch (status) {
      case StepStatus.pending:
        return Icon(Icons.circle_outlined,
            size: 16,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6));
      case StepStatus.running:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case StepStatus.success:
        final extColors = Theme.of(context).extension<ExtendedColors>();
        return Icon(Icons.check_circle_rounded,
            size: 16, color: extColors?.success ?? colorScheme.primary);
      case StepStatus.failed:
        return Icon(Icons.cancel_rounded, size: 16, color: colorScheme.error);
      case StepStatus.skipped:
        return Icon(Icons.next_plan_outlined,
            size: 16, color: colorScheme.onSurfaceVariant);
    }
  }
}
