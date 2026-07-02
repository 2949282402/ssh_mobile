// ignore_for_file: invalid_use_of_protected_member, unused_element
part of '../llm_chat_screen.dart';

extension _ChatGeneration on _LlmChatScreenBodyState {
  Future<void> _send(BuildContext context, AiStrings strings) async {
    final text = _inputController.text.trim();
    await _sendText(context, strings, text: text, clearInput: true);
  }

  Future<void> _sendText(
    BuildContext context,
    AiStrings strings, {
    required String text,
    required bool clearInput,
    AiApprovedPlanRef? approvedPlanRef,
  }) async {
    if (text.isEmpty) return;
    final viewModel = context.read<AiChatViewModel>();
    if (viewModel.sending) return;

    final result =
        await viewModel.sendText(text: text, approvedPlanRef: approvedPlanRef);
    if (!mounted) return;

    if (result is SendTextApiKeyMissing) {
      await _showSettings(this.context, strings);
    } else if (result is SendTextSlashCommandOpenSkills) {
      await Navigator.of(this.context).pushNamed('/ai-skills');
      if (mounted) {
        _showCommandFeedback(strings.commandSkillsOpened, this.context);
      }
    } else if (result is SendTextSlashCommandOpenToolsSelector) {
      final availableTools = await _loadAvailableTools(strings);
      if (!mounted || availableTools == null) return;
      final next = await _openToolsSelector(
        context: this.context,
        strings: strings,
        availableTools: availableTools,
        initialTools: result.currentAllowedTools,
      );
      if (next != null && mounted) {
        viewModel.updateAllowedTools(viewModel.activeChatId!, next);
        _showCommandFeedback(
          strings.commandToolsUpdated(next.length),
          this.context,
        );
      }
    } else if (result is SendTextSlashCommandHandled) {
      _showCommandFeedback(result.feedback, this.context);
      if (clearInput) _inputController.clear();
      setState(() {
        _toolsExpanded = false;
      });
    } else if (result is SendTextSuccess) {
      if (clearInput) _inputController.clear();
      setState(() {
        _toolsExpanded = false;
      });
    }
  }

  void _continueAfterTimeout(AiStrings strings) {
    _sendText(
      context,
      strings,
      text: strings.continueAfterTimeoutPrompt,
      clearInput: false,
    );
  }

  bool _isTimeoutError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('timeout') || text.contains('超时');
  }

  Future<void> approvePlanAndExecute(DateTime assistantCreatedAt) async {
    final viewModel = context.read<AiChatViewModel>();
    final result = await viewModel.approvePlanAndExecute(assistantCreatedAt);
    if (!mounted) return;
    if (result is ApprovePlanExecutionBlocked) {
      await _showRuntimeHealthDialog(
        report: result.healthReport!,
        allowContinue: false,
      );
    } else if (result is ApprovePlanExecutionWarning) {
      final confirmed = await _showRuntimeHealthDialog(
        report: result.healthReport!,
        allowContinue: true,
      );
      if (confirmed && mounted) {
        await viewModel.approvePlanAndExecute(
          assistantCreatedAt,
          forceAfterWarning: true,
        );
      }
    }
  }

  Future<bool> _showRuntimeHealthDialog({
    required ClientRuntimeHealthReport report,
    required bool allowContinue,
  }) async {
    final isEn = context.read<AppSettings>().language == AppLanguage.en;
    final colorScheme = Theme.of(context).colorScheme;
    final title = allowContinue
        ? (isEn ? 'Runtime warnings' : '运行环境风险')
        : (isEn ? 'Runtime check blocked execution' : '运行环境检查阻止执行');
    final issues = report.issues;
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  allowContinue
                      ? (isEn
                          ? 'The plan can run, but the client device has conditions that may interrupt long agent work.'
                          : '计划可以继续执行，但客户端设备存在可能影响长时间 Agent 任务的风险。')
                      : (isEn
                          ? 'Fix the following client-side issues before running this plan.'
                          : '请先处理以下客户端问题，再执行此计划。'),
                ),
                const SizedBox(height: 12),
                for (final issue in issues) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        issue.severity == ClientRuntimeHealthStatus.blocking
                            ? Icons.error_outline
                            : Icons.warning_amber_outlined,
                        size: 18,
                        color:
                            issue.severity == ClientRuntimeHealthStatus.blocking
                                ? colorScheme.error
                                : colorScheme.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              issue.title,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(issue.detail),
                            const SizedBox(height: 2),
                            Text(
                              issue.recommendation,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(isEn ? 'Close' : '关闭'),
          ),
          TextButton(
            onPressed: () async {
              await ClientSystemToolService.instance.openAppSettings();
              if (ctx.mounted) Navigator.of(ctx).pop(false);
            },
            child: Text(isEn ? 'App Settings' : '系统设置'),
          ),
          if (allowContinue)
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(isEn ? 'Continue' : '继续执行'),
            ),
        ],
      ),
    );
    return result == true;
  }

  void _stopGeneration() {
    final viewModel = context.read<AiChatViewModel>();
    viewModel.stopGeneration();
  }

  Future<bool> _confirmChatAction({
    required String title,
    required String content,
    required String confirmLabel,
    required AiStrings strings,
  }) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _confirmRegenerateAssistant(
    int messageIndex,
    AiStrings strings,
  ) async {
    final en = strings.language == AppLanguage.en;
    final confirmed = await _confirmChatAction(
      title: en ? 'Regenerate this reply?' : '确认重新生成这条回复吗？',
      content: en
          ? 'This will replace this assistant message and regenerate from this point. Continue?'
          : '这会替换这条 AI 回复并从该位置重新生成。确定继续吗？',
      confirmLabel: en ? 'Regenerate' : '重新生成',
      strings: strings,
    );
    if (!confirmed) return;
    await _regenerateAssistant(messageIndex);
  }

  Future<void> _confirmBranchFromAssistant(
    int messageIndex,
    AiStrings strings,
  ) async {
    final en = strings.language == AppLanguage.en;
    final confirmed = await _confirmChatAction(
      title: en ? 'Create a chat branch?' : '确认创建聊天分支吗？',
      content: en
          ? 'This creates a new chat thread from this message and continues independently from here.'
          : '将从该消息创建一个新的聊天分支，并从这里继续新对话。',
      confirmLabel: en ? 'Create branch' : '创建分支',
      strings: strings,
    );
    if (!confirmed) return;
    await _branchFromAssistant(messageIndex, strings);
  }

  Future<void> _regenerateAssistant(int messageIndex) async {
    final viewModel = context.read<AiChatViewModel>();
    await viewModel.regenerateAssistant(messageIndex);
  }

  Future<void> _editUserMessage(int messageIndex, AiStrings strings) async {
    final activeChat = _activeChat;
    if (activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'user') return;

    final editedText = await _showEditUserDialog(target.text, strings);
    if (!mounted || editedText == null) return;
    final trimmedEditedText = editedText.trim();
    if (trimmedEditedText.isEmpty) return;

    final viewModel = context.read<AiChatViewModel>();
    await viewModel.editUserMessage(messageIndex, trimmedEditedText);
  }

  Future<String?> _showEditUserDialog(
    String text,
    AiStrings strings,
  ) async {
    return showDialog<String>(
      context: context,
      builder: (_) => EditUserMessageDialog(
        initialText: text,
        strings: strings,
      ),
    );
  }

  Future<void> _branchFromAssistant(
    int messageIndex,
    AiStrings strings,
  ) async {
    final viewModel = context.read<AiChatViewModel>();
    viewModel.branchFromAssistant(messageIndex);
  }

  void _scrollToBottom({bool jump = false}) {
    _pendingScrollJump = _pendingScrollJump || jump;
    if (_scrollToBottomScheduled) return;
    _scrollToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomScheduled = false;
      final shouldJump = _pendingScrollJump;
      _pendingScrollJump = false;
      if (!_scrollController.hasClients) return;
      final viewModel = context.read<AiChatViewModel>();
      if (!shouldJump && viewModel.sending && !_isUserAtBottom.value) return;
      if (shouldJump || viewModel.sending) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        _setUserAtBottom(true);
        return;
      }
      _setUserAtBottom(true);
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  bool _isNearBottom(ScrollMetrics metrics) {
    return (metrics.maxScrollExtent - metrics.pixels) <=
        _LlmChatScreenBodyState._scrollBottomDistance;
  }

  void _updateUserScrollPosition(ScrollMetrics metrics) {
    _setUserAtBottom(_isNearBottom(metrics));
  }
}
