import 'dart:async';
import 'dart:convert';

// ignore_for_file: unused_element

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'client_webview_screen.dart';
import '../features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import '../features/ai_chat/services/ai_chat_message_mapper.dart';
import '../features/playbook/models/playbook.dart';
import '../services/agent_model_profile.dart';
import '../services/app_settings.dart';
import '../services/llm_chat_service.dart';
import '../services/multi_agent_coordinator.dart';
import '../services/performance_monitor_service.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/playbook_service.dart';
import '../services/rag_service.dart';
import '../widgets/overflow_scroll_text.dart';

part 'llm_chat/assistant_run_indicator.dart';
part 'llm_chat/llm_settings_screen.dart';
part 'llm_chat/message_bubble.dart';
part 'llm_chat/history_panel.dart';
part 'llm_chat/chat_tools_bar.dart';
part 'llm_chat/tool_approval_panel.dart';
part 'llm_chat/ai_strings.dart';
part 'llm_chat/chat_slash_commands.dart';
part 'llm_chat/chat_attachments.dart';
part 'llm_chat/chat_rag_sheet.dart';
part 'llm_chat/chat_generation.dart';
part 'llm_chat/prompt_customizer_dialog.dart';

const List<String> _defaultModels = [
  'deepseek-v4-flash',
  'deepseek-v4-pro',
];

@visibleForTesting
List<String> resolveFetchedModelOptions({
  required Iterable<String> fetchedModels,
  required Iterable<String> fallbackModels,
}) {
  return AiChatViewModel.resolveFetchedModelOptions(
    fetchedModels: fetchedModels,
    fallbackModels: fallbackModels,
  );
}

@visibleForTesting
List<String> buildInitialModelOptions({
  required String currentModel,
  required Iterable<String> cachedModels,
}) {
  final seededModels = resolveFetchedModelOptions(
    fetchedModels: cachedModels,
    fallbackModels: _defaultModels,
  );
  final normalizedCurrentModel = currentModel.trim();
  return {
    ...seededModels,
    if (normalizedCurrentModel.isNotEmpty) normalizedCurrentModel,
  }.toList()
    ..sort();
}

@visibleForTesting
String buildApprovedPlanExecutionContext({
  required String userText,
  required AiChatMessageRecord planMessage,
  required AppLanguage language,
}) {
  final isEn = language == AppLanguage.en;
  final steps = planMessage.todoSteps
      .map((step) => {
            'taskId': step.id,
            'name': step.name,
            'command': step.command,
            'description': step.description,
            if (step.connectionId?.trim().isNotEmpty == true)
              'connectionId': step.connectionId,
          })
      .toList(growable: false);
  return [
    isEn ? 'Approved execution plan:' : '已批准执行计划：',
    isEn
        ? 'Use these persisted todoSteps as the source of truth. Execute them sequentially in order. Do not recreate task ids or reparse any earlier playbook text.'
        : '以下持久化 todoSteps 是唯一执行依据。请严格按顺序执行，不要重新创建 taskId，也不要重新解析旧的 playbook 文本。',
    isEn
        ? 'Call client_task_update with status="running" when each step starts, then update it to success, failed, or skipped with stdout/stderr when the step finishes.'
        : '每一步开始时调用 client_task_update(status="running")，完成后再更新为 success、failed 或 skipped，并尽量写入 stdout/stderr。',
    isEn ? 'Persisted steps:' : '持久化步骤：',
    jsonEncode(steps),
    '',
    isEn ? 'User execution trigger:' : '用户执行触发：',
    userText,
  ].join('\n');
}

class LlmChatScreen extends StatelessWidget {
  final bool active;
  final ValueChanged<bool>? onHistoryVisibilityChanged;
  final String? initialText;

  const LlmChatScreen({
    super.key,
    this.active = true,
    this.onHistoryVisibilityChanged,
    this.initialText,
  });

  static List<Map<String, dynamic>> buildMultipartContent(
    String textContent,
    List<AiChatAttachment> attachments,
  ) {
    return AiChatMessageMapper.buildMultipartContent(textContent, attachments);
  }

  @override
  Widget build(BuildContext context) {
    // Provider Lifecycle choice: AiChatViewModel is registered locally here
    // rather than globally in main.dart because the chat state is only consumed
    // within the LlmChatScreen subtree. The parent HomeScreen keeps this tab's
    // state alive using keepAliveAfterFirstBuild, ensuring it behaves as a
    // single instance while the app is running.
    return ChangeNotifierProvider<AiChatViewModel>(
      create: (context) => AiChatViewModel(
        storageService: context.read<StorageService>(),
        sshService: context.read<SshService>(),
        sftpService: context.read<SftpService>(),
        performanceMonitorService: context.read<PerformanceMonitorService>(),
        playbookService: context.read<PlaybookService>(),
        ragService: context.read<RagService>(),
        appSettings: context.read<AppSettings>(),
      )..loadInitialDraft(),
      child: _LlmChatScreenBody(
        active: active,
        onHistoryVisibilityChanged: onHistoryVisibilityChanged,
        initialText: initialText,
      ),
    );
  }
}

class _LlmChatScreenBody extends StatefulWidget {
  final bool active;
  final ValueChanged<bool>? onHistoryVisibilityChanged;
  final String? initialText;

  const _LlmChatScreenBody({
    required this.active,
    this.onHistoryVisibilityChanged,
    this.initialText,
  });

  @override
  State<_LlmChatScreenBody> createState() => _LlmChatScreenBodyState();
}

extension _AiMessageActionStrings on _AiStrings {
  String get saveAndSend =>
      language == AppLanguage.en ? 'Save and send' : '保存并发送';
  String get editMessage =>
      language == AppLanguage.en ? 'Edit message' : '编辑消息';
  String get branchSuffix => language == AppLanguage.en ? 'Branch' : '分支';
}

extension _AiToolBarStrings on _AiStrings {
  String get tools => language == AppLanguage.en ? 'Tools' : '工具';
  String get close => language == AppLanguage.en ? 'Close' : '关闭';
}

extension _AiSkillToolbarStrings on _AiStrings {
  String get skills => language == AppLanguage.en ? 'Skills' : '技能';
  String get webView => language == AppLanguage.en ? 'WebView' : '网页';
  String get attachImage => language == AppLanguage.en ? 'Image' : '图片';
  String get attachFile => language == AppLanguage.en ? 'File' : '文件';
  String get promptLabel => language == AppLanguage.en ? 'Prompt' : '提示词';
}

extension _AiToolbarActionStrings on _AiStrings {
  String get serverTarget => language == AppLanguage.en ? 'Server' : '服务器';
  String get templates => language == AppLanguage.en ? 'Templates' : '妯℃澘';
  String get noDefaultServer =>
      language == AppLanguage.en ? 'No default server' : '不指定默认服务器';
  String get quickSkill =>
      language == AppLanguage.en ? 'Use Skill' : '临时 Skill';
  String get quickSkillActive =>
      language == AppLanguage.en ? 'Skill active' : 'Skill 已启用';
  String get noQuickSkill =>
      language == AppLanguage.en ? 'No temporary skill' : '不启用临时 Skill';
  String get noSkills =>
      language == AppLanguage.en ? 'No custom skills yet' : '还没有自定义 Skills';
}

extension _AiRunStatusStrings on _AiStrings {
  String get assistantPreparing =>
      language == AppLanguage.en ? 'Preparing response...' : '模型正在准备回答...';
  String get assistantThinking =>
      language == AppLanguage.en ? 'Thinking...' : '模型正在思考...';
  String get assistantResponding =>
      language == AppLanguage.en ? 'Generating answer...' : '正在输出回答...';
  String get assistantProcessingToolResult =>
      language == AppLanguage.en ? 'Processing tool result...' : '正在处理工具结果...';
  String get assistantProcessingApproval => language == AppLanguage.en
      ? 'Processing approval decision...'
      : '正在处理审批结果...';
  String get assistantCollaborating => language == AppLanguage.en
      ? 'Coordinating helper agents...'
      : '正在协调多 Agent 协作...';

  String get assistantToolBudgetExtended => language == AppLanguage.en
      ? 'Tool budget extended. Please review tool use...'
      : '工具预算已扩展，请留意工具调用是否合理...';
  String get assistantToolBudgetAudit => language == AppLanguage.en
      ? 'Auditing tool usage before continuing...'
      : '继续前正在审计工具调用...';
  String get assistantToolBudgetStopped => language == AppLanguage.en
      ? 'Tool usage stopped after safety audit...'
      : '安全审计后已停止继续调用工具...';

  String assistantRunningTool(String toolName) {
    final name = toolName.trim();
    if (language == AppLanguage.en) {
      return name.isEmpty ? 'Running tool...' : 'Running tool: $name';
    }
    return name.isEmpty ? '正在调用工具...' : '正在调用工具：$name';
  }

  String assistantAwaitingApproval(String serverName) {
    final name = serverName.trim();
    if (language == AppLanguage.en) {
      return name.isEmpty
          ? 'Waiting for tool approval...'
          : 'Waiting for tool approval on $name...';
    }
    return name.isEmpty ? '等待确认工具操作...' : '等待确认 $name 上的工具操作...';
  }
}

class _LlmChatScreenBodyState extends State<_LlmChatScreenBody>
    with
        AutomaticKeepAliveClientMixin<_LlmChatScreenBody>,
        SingleTickerProviderStateMixin {
  static const double _scrollBottomDistance = 48;
  final TextEditingController _inputController = TextEditingController();
  late final FocusNode _inputFocusNode;
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _historySlideController;
  Animation<double>? _historySlideAnimation;
  final ValueNotifier<double> _historyPanelExtent = ValueNotifier(0);
  bool _toolsExpanded = false;
  bool _isUserAtBottom = true;
  bool _scrollToBottomScheduled = false;
  bool _pendingScrollJump = false;
  StreamSubscription? _scrollSubscription;

  AiChatRecord? get _activeChat => context.read<AiChatViewModel>().activeChat;

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _inputController.text = widget.initialText!;
    }
    _checkPendingDiagnosticPrompt();
    _inputFocusNode = FocusNode(onKeyEvent: _handleInputKeyEvent);
    _inputFocusNode.addListener(_onInputFocusChanged);
    _historySlideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        final animation = _historySlideAnimation;
        if (animation == null || !mounted) return;
        _setHistoryPanelExtent(animation.value);
      });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final viewModel = context.read<AiChatViewModel>();
      _scrollSubscription = viewModel.scrollRequests.listen((_) {
        _scrollToBottom();
      });
    });
  }

  @override
  void didUpdateWidget(covariant _LlmChatScreenBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _scrollToBottom(jump: true);
    }
    if (widget.active) {
      _checkPendingDiagnosticPrompt();
    }
  }

  @override
  void dispose() {
    _scrollSubscription?.cancel();
    _historySlideController.dispose();
    _historyPanelExtent.dispose();
    _inputFocusNode.removeListener(_onInputFocusChanged);
    _inputFocusNode.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void sendDirectCommand(String text) {
    final viewModel = context.read<AiChatViewModel>();
    if (viewModel.sending) return;
    final strings = _AiStrings(context.read<AppSettings>().language);
    _sendText(context, strings, text: text, clearInput: true);
  }

  void _setUserAtBottom(bool atBottom) {
    if (_isUserAtBottom == atBottom) return;
    if (!mounted) {
      _isUserAtBottom = atBottom;
      return;
    }
    setState(() => _isUserAtBottom = atBottom);
  }

  void _checkPendingDiagnosticPrompt() {
    try {
      final viewModel = context.read<AiChatViewModel>();
      final prompt = viewModel.checkPendingDiagnosticPrompt();
      if (prompt != null) {
        _inputController.text = prompt;
      }
    } catch (_) {}
  }

  void _onInputFocusChanged() {
    if (_inputFocusNode.hasFocus) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        _scrollToBottom(jump: false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _AiStrings(language);
    final colorScheme = Theme.of(context).colorScheme;
    final viewModel = context.watch<AiChatViewModel>();
    final activeChat = viewModel.activeChat;

    if (viewModel.loading || activeChat == null) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final visibleMessages = activeChat.messages.isEmpty
        ? [
            AiChatMessageRecord(
              role: 'assistant',
              text: strings.welcome,
              createdAt: DateTime.now(),
            ),
          ]
        : activeChat.messages;
    final contextTokens = viewModel.contextTokensFor(activeChat);
    final contextPercent = viewModel.contextWindowTokens <= 0
        ? 0.0
        : contextTokens / viewModel.contextWindowTokens;

    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  border: Border(
                    bottom: BorderSide(color: colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: strings.history,
                      icon: const Icon(Icons.menu_rounded),
                      onPressed: () => _showHistory(context, strings),
                    ),
                    Expanded(
                      child: TweenAnimationBuilder<double>(
                        key: ValueKey('chat-title-${activeChat.id}'),
                        tween: Tween(begin: 0, end: 1),
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, child) {
                          return Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(12 * (1 - value), 0),
                              child: child,
                            ),
                          );
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OverflowScrollText(
                              activeChat.title,
                              selectable: false,
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            OverflowScrollText(
                              _contextUsage(
                                contextTokens,
                                viewModel.contextWindowTokens,
                                contextPercent,
                              ),
                              selectable: false,
                              maxLines: 1,
                              style: TextStyle(
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.62),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: strings.newChat,
                      icon: const Icon(Icons.add_comment_outlined),
                      onPressed: viewModel.sending
                          ? null
                          : () => viewModel.createChatFromSettings(),
                    ),
                    IconButton(
                      tooltip: strings.settings,
                      icon: const Icon(Icons.tune_rounded),
                      onPressed: () => _showSettings(context, strings),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey('chat-body-${activeChat.id}'),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, 18 * (1 - value)),
                        child: child,
                      ),
                    );
                  },
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.metrics.axis == Axis.vertical &&
                          (notification is UserScrollNotification ||
                              notification is ScrollEndNotification)) {
                        _updateUserScrollPosition(notification.metrics);
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scrollController,
                      cacheExtent: 900,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                      itemCount: visibleMessages.length,
                      itemBuilder: (context, index) {
                        final message = visibleMessages[index];
                        final streamingTextListenable =
                            viewModel.streamingTextFor(activeChat.id, message);
                        final streamingStatusListenable = viewModel
                            .streamingStatusFor(activeChat.id, message);
                        return RepaintBoundary(
                          key: ValueKey(
                            '${message.role}-${message.createdAt.microsecondsSinceEpoch}',
                          ),
                          child: _MessageBubble(
                            chatId: activeChat.id,
                            index: index,
                            message: message,
                            streamingTextListenable: streamingTextListenable,
                            streamingStatusListenable:
                                streamingStatusListenable,
                            canAct: !viewModel.sending &&
                                activeChat.messages == visibleMessages,
                            onEditUser: message.role == 'user'
                                ? () => _editUserMessage(index, strings)
                                : null,
                            onRegenerate: message.role == 'assistant'
                                ? () =>
                                    _confirmRegenerateAssistant(index, strings)
                                : null,
                            onBranch: message.role == 'assistant'
                                ? () =>
                                    _confirmBranchFromAssistant(index, strings)
                                : null,
                            onContinueTimeout: message.role == 'error' &&
                                    index == visibleMessages.length - 1 &&
                                    _isTimeoutError(message.text)
                                ? () => _continueAfterTimeout(strings)
                                : null,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              if (viewModel.pendingApproval?.chatId == activeChat.id)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height < 700
                        ? MediaQuery.sizeOf(context).height * 0.52
                        : 420,
                  ),
                  child: _ToolApprovalPanel(
                    pending: viewModel.pendingApproval!,
                    strings: strings,
                    onApprove: () =>
                        viewModel.resolvePendingApproval(approved: true),
                    onReject: () =>
                        viewModel.resolvePendingApproval(approved: false),
                  ),
                ),
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    border: Border(
                      top: BorderSide(color: colorScheme.outlineVariant),
                    ),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        (() {
                          final isPlanInput =
                              _inputController.text.trim().startsWith('/plan');
                          final showPlanMode =
                              activeChat.planMode || isPlanInput;
                          if (!showPlanMode) return const SizedBox.shrink();
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color:
                                    colorScheme.primary.withValues(alpha: 0.24),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.edit_note_rounded,
                                  size: 18,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    strings.language == AppLanguage.en
                                        ? 'Plan Mode Active (Read-only diagnostics & planning)'
                                        : '规划模式已启用 (仅进行只读诊断与方案规划)',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  onTap: () async {
                                    if (isPlanInput) {
                                      setState(() {
                                        _inputController.clear();
                                      });
                                    }
                                    if (activeChat.planMode) {
                                      await _setPlanModeFromUi(
                                        chat: activeChat,
                                        enabled: false,
                                        strings: strings,
                                      );
                                    }
                                  },
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ],
                            ),
                          );
                        })(),
                        if (_shouldShowSlashCommandPanel)
                          _buildSlashCommandPanel(context, strings),
                        if (viewModel.pendingAttachments.isNotEmpty)
                          _buildAttachmentPreview(),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _inputController,
                                focusNode: _inputFocusNode,
                                minLines: 1,
                                maxLines: 3,
                                textInputAction: TextInputAction.newline,
                                decoration:
                                    const InputDecoration(isDense: true),
                                onSubmitted: _isDesktopPlatform
                                    ? null
                                    : (_) => _send(context, strings),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: strings.tools,
                              icon: AnimatedRotation(
                                turns: _toolsExpanded ? 0.125 : 0,
                                duration: const Duration(milliseconds: 180),
                                child: const Icon(Icons.add_rounded),
                              ),
                              onPressed: () {
                                setState(
                                    () => _toolsExpanded = !_toolsExpanded);
                              },
                            ),
                            const SizedBox(width: 4),
                            IconButton.filled(
                              tooltip: viewModel.sending
                                  ? strings.stop
                                  : strings.send,
                              icon: Icon(
                                viewModel.sending
                                    ? Icons.stop_rounded
                                    : Icons.send_rounded,
                              ),
                              onPressed: viewModel.sending
                                  ? _stopGeneration
                                  : () => _send(context, strings),
                            ),
                          ],
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: _toolsExpanded
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: _ChatToolsBar(
                                    skillsLabel: strings.skills,
                                    serverLabel: _selectedServerLabel(strings),
                                    webViewLabel: strings.webView,
                                    imageLabel: strings.attachImage,
                                    fileLabel: strings.attachFile,
                                    ragLabel: strings.ragTitle,
                                    promptLabel: strings.promptLabel,
                                    onServerTap: () =>
                                        _selectTargetServer(strings),
                                    onSkillsTap: () {
                                      Navigator.pushNamed(
                                          context, '/ai-skills');
                                    },
                                    onWebViewTap: () =>
                                        _openClientWebView(activeChat.id),
                                    onImageTap: () => _pickImage(strings),
                                    onFileTap: () => _pickFile(strings),
                                    onRagTap: () =>
                                        _showRagBottomSheet(context, strings),
                                    onPromptTap: () =>
                                        _showPromptCustomizer(strings),
                                  ),
                                )
                              : const SizedBox(width: double.infinity),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          _buildHistoryOverlay(context, strings),
          if (_shouldShowJumpToBottomButton())
            Positioned(
              right: 14,
              bottom: 106,
              child: FloatingActionButton.small(
                onPressed: () => _scrollToBottom(jump: true),
                child: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ),
        ],
      ),
    );
  }

  String _selectedServerLabel(_AiStrings strings) {
    final viewModel = context.read<AiChatViewModel>();
    if (viewModel.selectedConnectionIds.isEmpty) return strings.serverTarget;
    if (viewModel.selectedConnectionIds.length == 1) {
      final id = viewModel.selectedConnectionIds.first;
      final connection = viewModel.getConnection(id);
      return connection == null ? strings.serverTarget : connection.name;
    }
    return strings.language == AppLanguage.en
        ? '${viewModel.selectedConnectionIds.length} Servers'
        : '${viewModel.selectedConnectionIds.length} 台服务器';
  }

  Future<void> _selectTargetServer(_AiStrings strings) async {
    final viewModel = context.read<AiChatViewModel>();
    if (viewModel.connections.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.language == AppLanguage.en
                ? 'No configured servers.'
                : '没有配置服务器。'),
          ),
        );
      }
      return;
    }

    final selected = Set<String>.from(viewModel.selectedConnectionIds);
    final result = await showModalBottomSheet<Set<String>?>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            strings.language == AppLanguage.en
                                ? 'Select target servers'
                                : '选择目标服务器',
                            style: Theme.of(sheetContext)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (selected.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              setSheetState(() => selected.clear());
                            },
                            child: Text(strings.language == AppLanguage.en
                                ? 'Clear all'
                                : '清空全部'),
                          ),
                      ],
                    ),
                    const Divider(),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final connection in viewModel.connections)
                            CheckboxListTile(
                              value: selected.contains(connection.id),
                              title: Text(connection.name),
                              subtitle: Text(
                                  '${connection.username}@${connection.host}:${connection.port}'),
                              onChanged: (val) {
                                setSheetState(() {
                                  if (val == true) {
                                    selected.add(connection.id);
                                  } else {
                                    selected.remove(connection.id);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: Text(strings.cancel),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () =>
                              Navigator.pop(sheetContext, selected),
                          child: Text(strings.save),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    if (!mounted) return;
    if (result != null) {
      viewModel.updateSelectedConnections(result);
    }
  }

  Future<void> _openClientWebView(String chatId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClientWebViewScreen(chatId: chatId),
      ),
    );
  }

  Future<void> _showPromptCustomizer(_AiStrings strings) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PromptCustomizerDialog(strings: strings),
    );
  }

  KeyEventResult _handleInputKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopPlatform || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    if (HardwareKeyboard.instance.isControlPressed) {
      _insertInputNewline();
    } else {
      final strings = _AiStrings(context.read<AppSettings>().language);
      unawaited(_send(context, strings));
    }
    return KeyEventResult.handled;
  }

  bool get _isDesktopPlatform {
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  void _insertInputNewline() {
    final value = _inputController.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final nextText = text.replaceRange(start, end, '\n');
    _inputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }

  void updateState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  Future<void> _showSettings(BuildContext context, _AiStrings strings) async {
    final viewModel = context.read<AiChatViewModel>();
    final settingsData = await viewModel.loadLlmSettingsData();
    final settings = settingsData['settings'] as AiConnectionSettings;
    final cachedModels = settingsData['cachedModels'] as List<String>;
    final baseUrlHistory = settingsData['baseUrlHistory'] as List<String>;
    final apiKeyHistory =
        settingsData['apiKeyHistory'] as List<AiApiKeyHistoryEntry>;

    if (!context.mounted) return;
    viewModel.logLlmSettingsOpened(settings);

    if (mounted) {
      final nextSettings = await Navigator.of(context).push<_PendingAiSettings>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _LlmSettingsScreen(
            initialSettings: settings,
            initialModels: buildInitialModelOptions(
              currentModel: settings.model,
              cachedModels: cachedModels,
            ),
            initialBaseUrlHistory: baseUrlHistory,
            initialApiKeyHistory: apiKeyHistory,
          ),
        ),
      );
      if (nextSettings == null) return;
      if (!mounted) return;
      final activeChat = viewModel.activeChat;
      final nextModel = nextSettings.model.trim();
      if (activeChat != null &&
          nextModel.isNotEmpty &&
          activeChat.model != nextModel) {
        final updatedChat = activeChat.copyWith(
          model: nextModel,
          updatedAt: DateTime.now(),
        );
        await viewModel.updateActiveChat(updatedChat);
      }
      // Reload VM draft values
      await viewModel.loadInitialDraft();
    }
  }

  Future<void> _deleteChat(String id) async {
    final viewModel = context.read<AiChatViewModel>();
    await viewModel.deleteChat(id);
    _scrollToBottom(jump: true);
  }

  String _contextUsage(int used, int limit, double ratio) {
    final percent = (ratio * 100).clamp(0, 999).toStringAsFixed(1);
    return '${_compactTokens(used)} / ${AiContextWindowSize.label(limit)} ($percent%)';
  }

  String _compactTokens(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(2)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }

  @override
  bool get wantKeepAlive => true;
}
