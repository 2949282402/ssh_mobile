// ignore_for_file: invalid_use_of_protected_member, unused_element
part of '../llm_chat_screen.dart';

bool shouldFollowChatScrollRequest({
  required bool explicit,
  required bool isUserAtBottom,
}) {
  return explicit || isUserAtBottom;
}

@visibleForTesting
Future<void> runPlanApprovalUiFlow({
  required AiStrings strings,
  required Future<ApprovePlanExecutionResult> Function(bool forceAfterWarning)
  approve,
  required Future<bool> Function(
    ClientRuntimeHealthReport report,
    bool allowContinue,
  )
  showRuntimeHealth,
  required Future<void> Function() openLlmSettings,
  required void Function(String message) showFeedback,
}) async {
  Future<void> dispatch(
    ApprovePlanExecutionResult result, {
    required bool allowWarning,
  }) async {
    if (result is ApprovePlanExecutionStarted) {
      showFeedback(strings.planApprovalStarting);
      return;
    }
    if (result is ApprovePlanExecutionBlocked) {
      final report = result.healthReport;
      if (report == null) {
        showFeedback(strings.planApprovalFailed);
        return;
      }
      await showRuntimeHealth(report, false);
      return;
    }
    if (result is ApprovePlanExecutionWarning) {
      final report = result.healthReport;
      if (report == null || !allowWarning) {
        showFeedback(strings.planApprovalFailed);
        return;
      }
      final confirmed = await showRuntimeHealth(report, true);
      if (!confirmed) return;
      final forcedResult = await approve(true);
      await dispatch(forcedResult, allowWarning: false);
      return;
    }
    if (result is ApprovePlanExecutionApiKeyMissing) {
      showFeedback(strings.planApprovalApiKeyMissing);
      await openLlmSettings();
      return;
    }
    if (result is ApprovePlanExecutionPlanChanged) {
      showFeedback(strings.planApprovalPlanChanged);
      return;
    }
    if (result is ApprovePlanExecutionNoPlan) {
      showFeedback(strings.planApprovalNoPlan);
      return;
    }
    if (result is ApprovePlanExecutionFailed) {
      showFeedback(strings.planApprovalFailed);
      return;
    }
    if (result is ApprovePlanExecutionCancelled) {
      showFeedback(strings.planApprovalCancelled);
      return;
    }
    if (result is ApprovePlanExecutionAlreadySending) {
      showFeedback(strings.aiActionInProgress);
    }
  }

  final result = await approve(false);
  await dispatch(result, allowWarning: true);
}

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
    final targetChatId = viewModel.activeChatId;

    final result = await viewModel.sendText(
      text: text,
      approvedPlanRef: approvedPlanRef,
    );
    if (!context.mounted) return;

    if (result is SendTextApiKeyMissing) {
      await _showSettings(strings);
    } else if (result is SendTextSlashCommandOpenSkills) {
      await Navigator.of(context).pushNamed('/ai-skills');
      if (context.mounted) {
        LlmChatCommandsHelper.showCommandFeedback(
          context,
          strings.commandSkillsOpened,
        );
      }
    } else if (result is SendTextSlashCommandOpenToolsSelector) {
      final availableTools = await LlmChatCommandsHelper.loadAvailableTools(
        context,
        strings,
      );
      if (!context.mounted || availableTools == null) return;
      final next = await LlmChatCommandsHelper.openToolsSelector(
        context: context,
        strings: strings,
        availableTools: availableTools,
        initialTools: result.currentAllowedTools,
      );
      if (next != null && context.mounted && targetChatId != null) {
        viewModel.updateAllowedTools(targetChatId, next);
        LlmChatCommandsHelper.showCommandFeedback(
          context,
          strings.commandToolsUpdated(next.length),
        );
      }
    } else if (result is SendTextSlashCommandHandled) {
      LlmChatCommandsHelper.showCommandFeedback(context, result.feedback);
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
    if (_planApprovalUiInFlight) return;
    setState(() => _planApprovalUiInFlight = true);
    final viewModel = context.read<AiChatViewModel>();
    final strings = AiStrings(context.read<AppSettings>().language);
    try {
      await runPlanApprovalUiFlow(
        strings: strings,
        approve: (forceAfterWarning) => viewModel.approvePlanAndExecute(
          assistantCreatedAt,
          forceAfterWarning: forceAfterWarning,
        ),
        showRuntimeHealth: (report, allowContinue) {
          if (!mounted) return Future<bool>.value(false);
          return _showRuntimeHealthDialog(
            report: report,
            allowContinue: allowContinue,
          );
        },
        openLlmSettings: () async {
          if (mounted) await _showSettings(strings);
        },
        showFeedback: (message) {
          if (mounted) {
            LlmChatCommandsHelper.showCommandFeedback(context, message);
          }
        },
      );
    } finally {
      if (mounted) setState(() => _planApprovalUiInFlight = false);
    }
  }

  Future<bool> _showRuntimeHealthDialog({
    required ClientRuntimeHealthReport report,
    required bool allowContinue,
  }) async {
    final strings = AiStrings(context.read<AppSettings>().language);
    return showRuntimeHealthPreflightDialog(
      context: context,
      report: report,
      allowContinue: allowContinue,
      strings: strings,
      onOpenSystemSettings: ClientSystemToolService.instance.openAppSettings,
    );
  }

  void _stopGeneration() {
    final viewModel = context.read<AiChatViewModel>();
    viewModel.stopGeneration();
  }

  Future<void> _confirmRegenerateAssistant(
    int messageIndex,
    AiStrings strings,
  ) async {
    final confirmed = await showChatActionConfirmation(
      context: context,
      title: strings.regenerateReplyTitle,
      message: strings.regenerateReplyMessage,
      confirmLabel: strings.regenerateReplyAction,
      strings: strings,
    );
    if (!confirmed) return;
    await _regenerateAssistant(messageIndex);
  }

  Future<void> _confirmBranchFromAssistant(
    int messageIndex,
    AiStrings strings,
  ) async {
    final confirmed = await showChatActionConfirmation(
      context: context,
      title: strings.createBranchTitle,
      message: strings.createBranchMessage,
      confirmLabel: strings.createBranchAction,
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

  Future<String?> _showEditUserDialog(String text, AiStrings strings) async {
    return showDialog<String>(
      context: context,
      builder: (_) =>
          EditUserMessageDialog(initialText: text, strings: strings),
    );
  }

  Future<void> _branchFromAssistant(int messageIndex, AiStrings strings) async {
    final viewModel = context.read<AiChatViewModel>();
    await viewModel.branchFromAssistant(messageIndex);
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
      if (!shouldFollowChatScrollRequest(
        explicit: shouldJump,
        isUserAtBottom: _isUserAtBottom.value,
      )) {
        return;
      }
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
