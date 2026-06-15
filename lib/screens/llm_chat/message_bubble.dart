part of '../llm_chat_screen.dart';

class _StreamingAssistantTarget {
  final String chatId;
  final DateTime assistantCreatedAt;

  const _StreamingAssistantTarget({
    required this.chatId,
    required this.assistantCreatedAt,
  });
}

class _MessageBubble extends StatelessWidget {
  final String chatId;
  final AiChatMessageRecord message;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;
  final bool canAct;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;
  final VoidCallback? onContinueTimeout;

  const _MessageBubble({
    required this.chatId,
    required this.message,
    this.streamingTextListenable,
    this.streamingStatusListenable,
    this.canAct = false,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
    this.onContinueTimeout,
  });

  @override
  Widget build(BuildContext context) {
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
              _TracePanel(
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
                  topLeft: const Radius.circular(12),
                  topRight: isUser
                      ? const Radius.circular(3)
                      : const Radius.circular(12),
                  bottomLeft: const Radius.circular(12),
                  bottomRight: isUser
                      ? const Radius.circular(12)
                      : const Radius.circular(3),
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
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final attachment in message.attachments)
                                  if (attachment.isImage &&
                                      attachment.dataBase64.isNotEmpty)
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.memory(
                                        base64Decode(attachment.dataBase64),
                                        width: 120,
                                        height: 120,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          width: 120,
                                          height: 40,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: colorScheme
                                                .surfaceContainerHighest,
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            attachment.fileName,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color:
                                                  colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.insert_drive_file_outlined,
                                            size: 14,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            attachment.fileName,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color:
                                                  colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                              ],
                            ),
                          ),
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
                          ),
                        ]
                      ],
                    ),
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

class _EditUserMessageDialog extends StatefulWidget {
  final String initialText;
  final _AiStrings strings;

  const _EditUserMessageDialog({
    required this.initialText,
    required this.strings,
  });

  @override
  State<_EditUserMessageDialog> createState() => _EditUserMessageDialogState();
}

class _EditUserMessageDialogState extends State<_EditUserMessageDialog> {
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
        valueListenable: streamingStatusListenable ?? _emptyStringListenable,
        builder: (context, status, _) {
          final displayText = value.isEmpty ? text : value;
          final hasText = displayText.trim().isNotEmpty;
          final label = status.trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (label.isNotEmpty || !hasText)
                _AssistantRunIndicator(
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
    return MarkdownBody(
      data: value.isEmpty ? '...' : value,
      selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(
        Theme.of(context),
      ).copyWith(
        p: TextStyle(
          color: colorScheme.onSurface,
          height: 1.35,
        ),
        code: TextStyle(
          color: colorScheme.onSurface,
          backgroundColor: colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.72,
          ),
        ),
        codeblockDecoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.72,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
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
              borderRadius: BorderRadius.circular(8),
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
                        borderRadius: BorderRadius.circular(8),
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

class _TracePanel extends StatelessWidget {
  final List<AiMessageTrace> traces;
  final String storageKey;

  const _TracePanel({
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
        borderRadius: BorderRadius.circular(8),
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
              _TraceEntry(
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

class _TraceEntry extends StatelessWidget {
  final AiMessageTrace trace;
  final int index;
  final String storageKey;

  const _TraceEntry({
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
        borderRadius: BorderRadius.circular(8),
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

class _ChatTodoPanel extends StatefulWidget {
  final String chatId;
  final AiChatMessageRecord message;

  const _ChatTodoPanel({
    required this.chatId,
    required this.message,
  });

  @override
  State<_ChatTodoPanel> createState() => _ChatTodoPanelState();
}

class _ChatTodoPanelState extends State<_ChatTodoPanel> {
  final Set<int> _expandedIndices = {};
  bool _todoExecuting = false;

  Future<void> _runSingleStep(BuildContext context, int index) async {
    if (_todoExecuting) return;
    final state = context.findAncestorStateOfType<_LlmChatScreenState>();
    if (state == null) return;

    setState(() => _todoExecuting = true);
    try {
      await state._runTodoStep(
        chatId: widget.chatId,
        message: widget.message,
        stepIndex: index,
      );
    } finally {
      if (mounted) {
        setState(() => _todoExecuting = false);
      }
    }
  }

  Future<void> _runAll(BuildContext context) async {
    if (_todoExecuting) return;
    final state = context.findAncestorStateOfType<_LlmChatScreenState>();
    if (state == null) return;

    setState(() => _todoExecuting = true);
    try {
      for (var i = 0; i < widget.message.todoSteps.length; i++) {
        final step = widget.message.todoSteps[i];
        if (step.status == StepStatus.pending ||
            step.status == StepStatus.failed) {
          await state._runTodoStep(
            chatId: widget.chatId,
            message: widget.message,
            stepIndex: i,
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _todoExecuting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEn = context.read<AppSettings>().language == AppLanguage.en;

    final hasActiveExecution = widget.message.todoSteps
        .any((s) => s.status == StepStatus.running);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(8),
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
              if (widget.message.todoSteps.any((s) =>
                  s.status == StepStatus.pending ||
                  s.status == StepStatus.failed))
                TextButton.icon(
                  onPressed: (hasActiveExecution || _todoExecuting)
                      ? null
                      : () => _runAll(context),
                  icon: const Icon(Icons.play_circle_outline, size: 16),
                  label: Text(
                    isEn ? 'Run All' : '一键运行',
                    style: const TextStyle(fontSize: 11),
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ],
          ),
          const Divider(height: 12),
          for (var i = 0; i < widget.message.todoSteps.length; i++) ...[
            _buildStepRow(context, i, widget.message.todoSteps[i], colorScheme, isEn),
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
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
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
                const SizedBox(width: 8),
                _buildActionWidget(context, index, step, colorScheme, isEn),
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
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.48),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Text(
                    step.command,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
                if (hasLogs) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.84),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '${step.stdout ?? ''}\n${step.stderr ?? ''}'.trim(),
                        style: const TextStyle(
                          fontFamily: 'monospace',
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
        return Icon(Icons.circle_outlined, size: 16, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6));
      case StepStatus.running:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case StepStatus.success:
        return const Icon(Icons.check_circle_rounded, size: 16, color: Colors.green);
      case StepStatus.failed:
        return const Icon(Icons.cancel_rounded, size: 16, color: Colors.red);
      case StepStatus.skipped:
        return Icon(Icons.next_plan_outlined, size: 16, color: colorScheme.onSurfaceVariant);
    }
  }

  Widget _buildActionWidget(
    BuildContext context,
    int index,
    AiTodoStep step,
    ColorScheme colorScheme,
    bool isEn,
  ) {
    if (step.status == StepStatus.running) {
      return const SizedBox.shrink();
    }
    if (step.status == StepStatus.success) {
      return Icon(
        Icons.verified_outlined,
        size: 16,
        color: colorScheme.primary.withValues(alpha: 0.6),
      );
    }

    final isFailed = step.status == StepStatus.failed;
    return SizedBox(
      height: 24,
      child: TextButton(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          backgroundColor: isFailed
              ? colorScheme.errorContainer.withValues(alpha: 0.4)
              : colorScheme.primaryContainer.withValues(alpha: 0.4),
        ),
        onPressed: _todoExecuting ? null : () => _runSingleStep(context, index),
        child: Text(
          isFailed
              ? (isEn ? 'Retry' : '重试')
              : (isEn ? 'Run' : '运行'),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.bold,
            color: isFailed ? colorScheme.error : colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
