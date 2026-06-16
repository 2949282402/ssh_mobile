// ignore_for_file: invalid_use_of_protected_member, unused_element
part of '../llm_chat_screen.dart';

extension _ChatGeneration on _LlmChatScreenBodyState {
  Future<void> _send(BuildContext context, _AiStrings strings) async {
    final text = _inputController.text.trim();
    await _sendText(context, strings, text: text, clearInput: true);
  }

  Future<void> _sendText(
    BuildContext context,
    _AiStrings strings, {
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
      await _showSettings(context, strings);
    } else if (result is SendTextSlashCommandOpenSkills) {
      await Navigator.of(context).pushNamed('/ai-skills');
      if (mounted) {
        _showCommandFeedback(strings.commandSkillsOpened, context);
      }
    } else if (result is SendTextSlashCommandOpenToolsSelector) {
      final availableTools = await _loadAvailableTools(strings);
      if (!mounted || availableTools == null) return;
      final next = await _openToolsSelector(
        context: context,
        strings: strings,
        availableTools: availableTools,
        initialTools: result.currentAllowedTools,
      );
      if (next != null && mounted) {
        viewModel.updateAllowedTools(viewModel.activeChatId!, next);
        _showCommandFeedback(strings.commandToolsUpdated(next.length), context);
      }
    } else if (result is SendTextSlashCommandHandled) {
      _showCommandFeedback(result.feedback, context);
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

  void _continueAfterTimeout(_AiStrings strings) {
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
    await viewModel.approvePlanAndExecute(assistantCreatedAt);
  }

  void _stopGeneration() {
    final viewModel = context.read<AiChatViewModel>();
    viewModel.stopGeneration();
  }

  Future<bool> _confirmChatAction({
    required String title,
    required String content,
    required String confirmLabel,
    required _AiStrings strings,
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
    _AiStrings strings,
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
    _AiStrings strings,
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

  Future<void> _editUserMessage(int messageIndex, _AiStrings strings) async {
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
    _AiStrings strings,
  ) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _EditUserMessageDialog(
        initialText: text,
        strings: strings,
      ),
    );
  }

  Future<void> _branchFromAssistant(
    int messageIndex,
    _AiStrings strings,
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
      if (!shouldJump && viewModel.sending && !_isUserAtBottom) return;
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

  void _setUserAtBottom(bool atBottom) {
    if (_isUserAtBottom == atBottom) return;
    if (!mounted) {
      _isUserAtBottom = atBottom;
      return;
    }
    setState(() => _isUserAtBottom = atBottom);
  }

  bool _isNearBottom(ScrollMetrics metrics) {
    return (metrics.maxScrollExtent - metrics.pixels) <=
        _LlmChatScreenBodyState._scrollBottomDistance;
  }

  void _updateUserScrollPosition(ScrollMetrics metrics) {
    _setUserAtBottom(_isNearBottom(metrics));
  }

  bool _shouldShowJumpToBottomButton() {
    final viewModel = context.read<AiChatViewModel>();
    if (!viewModel.sending) return false;
    if (!_scrollController.hasClients) return false;
    if (_isUserAtBottom) return false;
    if (_scrollController.position.maxScrollExtent <=
        _LlmChatScreenBodyState._scrollBottomDistance) {
      return false;
    }
    return true;
  }
}
