import 'dart:async';
import 'dart:convert';
import 'dart:ui';

// ignore_for_file: unused_element

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/client_webview/views/client_webview_screen.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_message_mapper.dart';
import 'package:ssh_mobile/services/agent_model_profile.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/client_health_advisor.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/llm_provider/llm_api_format.dart';
import 'package:ssh_mobile/services/multi_agent_coordinator.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';
import 'package:ssh_mobile/widgets/destructive_confirm_dialog.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'widgets/history_action_sheet.dart';

import 'widgets/message_bubble.dart';

part 'widgets/assistant_run_indicator.dart';
part 'widgets/llm_settings_screen.dart';
part 'widgets/history_panel.dart';
part 'widgets/chat_tools_bar.dart';
part 'widgets/tool_approval_panel.dart';
part 'widgets/ai_strings.dart';
part 'widgets/chat_slash_commands.dart';
part 'widgets/chat_attachments.dart';
part 'widgets/chat_rag_sheet.dart';
part 'widgets/chat_generation.dart';
part 'widgets/prompt_customizer_dialog.dart';
part 'widgets/chat_state_snapshots.dart';
part 'widgets/chat_header.dart';
part 'widgets/chat_message_list.dart';
part 'widgets/tool_approval_area.dart';
part 'widgets/jump_to_bottom_button.dart';
part 'widgets/chat_history_overlay.dart';
part 'widgets/chat_composer.dart';

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

extension AiMessageActionStrings on AiStrings {
  String get saveAndSend =>
      language == AppLanguage.en ? 'Save and send' : '保存并发送';
  String get editMessage =>
      language == AppLanguage.en ? 'Edit message' : '编辑消息';
  String get branchSuffix => language == AppLanguage.en ? 'Branch' : '分支';
}

extension AiToolBarStrings on AiStrings {
  String get tools => language == AppLanguage.en ? 'Tools' : '工具';
  String get close => language == AppLanguage.en ? 'Close' : '关闭';
}

extension AiSkillToolbarStrings on AiStrings {
  String get skills => language == AppLanguage.en ? 'Skills' : '技能';
  String get webView => language == AppLanguage.en ? 'WebView' : '网页';
  String get attachImage => language == AppLanguage.en ? 'Image' : '图片';
  String get attachFile => language == AppLanguage.en ? 'File' : '文件';
  String get promptLabel => language == AppLanguage.en ? 'Prompt' : '提示词';
}

extension AiToolbarActionStrings on AiStrings {
  String get serverTarget => language == AppLanguage.en ? 'Server' : '服务器';
  String get templates => language == AppLanguage.en ? 'Templates' : '模板';
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

extension AiRunStatusStrings on AiStrings {
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
  final ValueNotifier<bool> _isUserAtBottom = ValueNotifier(true);
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
    _isUserAtBottom.dispose();
    _inputFocusNode.removeListener(_onInputFocusChanged);
    _inputFocusNode.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void sendDirectCommand(String text) {
    final viewModel = context.read<AiChatViewModel>();
    if (viewModel.sending) return;
    final strings = AiStrings(context.read<AppSettings>().language);
    _sendText(context, strings, text: text, clearInput: true);
  }

  void _setUserAtBottom(bool atBottom) {
    if (_isUserAtBottom.value == atBottom) return;
    _isUserAtBottom.value = atBottom;
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
    final strings = AiStrings(language);

    return Selector<AiChatViewModel, _ChatShellSnapshot>(
      selector: (context, vm) => _ChatShellSnapshot(
        loading: vm.loading,
        hasActiveChat: vm.activeChat != null,
        activeChatId: vm.activeChatId,
      ),
      builder: (context, snapshot, child) {
        if (snapshot.loading || !snapshot.hasActiveChat) {
          return const Scaffold(
            body: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: _ChatMessageList(
                      scrollController: _scrollController,
                      onUserScroll: _updateUserScrollPosition,
                      onEditUser: (index) => _editUserMessage(index, strings),
                      onRegenerate: (index) =>
                          _confirmRegenerateAssistant(index, strings),
                      onBranch: (index) =>
                          _confirmBranchFromAssistant(index, strings),
                      onContinueTimeout: () => _continueAfterTimeout(strings),
                      onApprovePlanExecute: (createdAt) =>
                          approvePlanAndExecute(createdAt),
                      onRevisePlan: (chat) => _setPlanModeFromUi(
                        chat: chat,
                        enabled: true,
                        strings: strings,
                      ),
                    ),
                  ),
                  const _ChatToolApprovalArea(),
                  SafeArea(
                    top: false,
                    child: _ChatComposer(
                      inputController: _inputController,
                      inputFocusNode: _inputFocusNode,
                      toolsExpanded: _toolsExpanded,
                      onToolsExpandedChanged: (expanded) {
                        setState(() => _toolsExpanded = expanded);
                      },
                      onSubmit: () => _send(context, strings),
                      onStop: _stopGeneration,
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _ChatHeader(
                  onShowHistory: () => _showHistory(context, strings),
                  onShowSettings: () => _showSettings(context, strings),
                ),
              ),
              _ChatHistoryOverlay(strings: strings),
              _ChatJumpToBottomButton(
                scrollController: _scrollController,
                isUserAtBottom: _isUserAtBottom,
                onPressed: () => _scrollToBottom(jump: true),
              ),
            ],
          ),
        );
      },
    );
  }

  String _selectedServerLabel(AiStrings strings) {
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

  Future<void> _selectTargetServer(AiStrings strings) async {
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

  Future<void> _showPromptCustomizer(AiStrings strings) async {
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
      final strings = AiStrings(context.read<AppSettings>().language);
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

  Future<void> _showSettings(BuildContext context, AiStrings strings) async {
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

  Future<void> _deleteChat(AiChatRecord chat) async {
    final strings = AiStrings(context.read<AppSettings>().language);
    final confirmed = await DestructiveConfirmDialog.show(
      context,
      title: strings.deleteChatTitle,
      content: strings.deleteChatContent(chat.title),
      cancelLabel: strings.cancel,
      confirmLabel: strings.delete,
    );
    if (!confirmed || !mounted) return;
    final viewModel = context.read<AiChatViewModel>();
    await viewModel.deleteChat(chat.id);
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
