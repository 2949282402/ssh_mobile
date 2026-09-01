import 'dart:async';
import 'dart:convert';

// ignore_for_file: unused_element

import 'package:file_picker/file_picker.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:app_core/app_core.dart' as app_core;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:feature_ai/src/chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:feature_ai/src/chat/services/ai_chat_message_mapper.dart';
import 'package:feature_ai/src/chat/services/plan_command_parser.dart';
import 'package:feature_ai/src/chat/services/plan_approval_eligibility.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_ai/src/agent/agent_model_profile.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import '../services/llm_chat_service.dart';
import 'package:feature_ai/src/llm/provider/llm_api_format.dart';
import 'package:feature_ai/src/agent/multi_agent_coordinator.dart';
import 'package:app_ui/app_ui.dart';
import 'widgets/history_action_sheet.dart';
import 'widgets/attachment_image_thumbnail.dart';
import 'widgets/ai_strings.dart';

import 'widgets/message_bubble.dart';

part 'widgets/assistant_run_indicator.dart';
part 'widgets/llm_settings_screen.dart';
part 'widgets/llm_settings_widgets.dart';
part 'widgets/history_panel.dart';
part 'widgets/chat_tools_bar.dart';
part 'widgets/tool_approval_panel.dart';
part 'widgets/chat_slash_commands.dart';
part 'widgets/chat_attachments.dart';
part 'widgets/chat_rag_sheet.dart';
part 'widgets/chat_generation.dart';
part 'widgets/chat_action_confirm_dialog.dart';
part 'widgets/runtime_health_dialog.dart';
part 'widgets/target_server_picker_sheet.dart';
part 'widgets/prompt_customizer_dialog.dart';
part 'widgets/chat_state_snapshots.dart';
part 'widgets/chat_header.dart';
part 'widgets/chat_message_list.dart';
part 'widgets/tool_approval_area.dart';
part 'widgets/plan_approval_area.dart';
part 'widgets/jump_to_bottom_button.dart';
part 'widgets/chat_history_overlay.dart';
part 'widgets/chat_composer.dart';

const List<String> _defaultModels = ['deepseek-v4-flash', 'deepseek-v4-pro'];

/// App Shell 提供 WebView 页面构造器；WebView 实现本身在 Step19 迁移。
typedef AiWebViewScreenBuilder =
    Widget Function(BuildContext context, String chatId);

/// Step18 的安全占位页面；App Shell 注入真实 WebView 页面后不会使用它。
final class _AiWebViewUnavailableScreen extends StatelessWidget {
  const _AiWebViewUnavailableScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('WebView capability is not available in this context.'),
      ),
    );
  }
}

@visibleForTesting
double chatComposerMaxHeightFor({
  required double viewportHeight,
  required double keyboardInset,
  double textScale = 1,
}) {
  final visibleHeight = (viewportHeight - keyboardInset).clamp(
    0.0,
    double.infinity,
  );
  if (visibleHeight < 360) {
    final compactMinimum = 75 + ((textScale - 1).clamp(0.0, 1.0) * 25);
    return (visibleHeight - 76).clamp(compactMinimum, 200.0);
  }
  return (visibleHeight * 0.46).clamp(132.0, 360.0);
}

@visibleForTesting
bool shouldShowPlanApprovalForAvailableHeight({
  required double availableHeight,
  required double availableWidth,
  required double textScale,
}) {
  final normalizedScale = textScale.clamp(1.0, 2.0);
  final actionsStack = availableWidth < 400 || (14 * normalizedScale) > 18;
  final baseMinimumHeight = actionsStack ? 360.0 : 340.0;
  final minimumBottomControlsHeight =
      baseMinimumHeight + ((normalizedScale - 1) * 100);
  return availableHeight >= minimumBottomControlsHeight;
}

@visibleForTesting
bool shouldShowPlanModeBannerForAvailableHeight({
  required double availableHeight,
  required double textScale,
}) {
  final normalizedScale = textScale.clamp(1.0, 2.0);
  final minimumComposerHeight = 220 + ((normalizedScale - 1) * 40);
  return availableHeight >= minimumComposerHeight;
}

@visibleForTesting
double toolApprovalPanelMaxHeightFor({
  required double viewportHeight,
  required bool compactHeight,
}) {
  if (compactHeight) {
    return (viewportHeight * 0.58).clamp(180.0, 300.0);
  }
  return (viewportHeight * 0.46).clamp(240.0, 420.0);
}

@visibleForTesting
double historyPanelLeadingOffsetFor({
  required double width,
  required double progress,
}) {
  final normalizedProgress = progress.clamp(0.0, 1.0);
  return (normalizedProgress - 1) * width;
}

@visibleForTesting
int chatToolColumnCountFor(double availableWidth) {
  return (availableWidth / 88).floor().clamp(3, 6);
}

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
  }.toList()..sort();
}

@visibleForTesting
String buildApprovedPlanExecutionContext({
  required String userText,
  required AiChatMessageRecord planMessage,
  required AppLanguage language,
}) {
  final isEn = language == AppLanguage.en;
  final steps = planMessage.todoSteps
      .map(
        (step) => {
          'taskId': step.id,
          'name': step.name,
          'command': step.command,
          'description': step.description,
          if (step.connectionId?.trim().isNotEmpty == true)
            'connectionId': step.connectionId,
        },
      )
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
  final AiChatViewModel Function(BuildContext context)? viewModelFactory;
  final AiWebViewScreenBuilder? webViewScreenBuilder;

  const LlmChatScreen({
    super.key,
    this.active = true,
    this.onHistoryVisibilityChanged,
    this.initialText,
    this.viewModelFactory,
    this.webViewScreenBuilder,
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
    AiChatViewModel? viewModel;
    try {
      viewModel = viewModelFactory?.call(context);
    } catch (_) {}

    if (viewModel == null) {
      try {
        final storage = context.read<AiStoragePort?>();
        final appSettings = context.read<AppSettings?>();
        if (storage != null && appSettings != null) {
          viewModel = AiChatViewModel(
            storageService: storage,
            sshService: context.read<SshService>(),
            sftpService: context.read<SftpService>(),
            performanceMonitorService:
                context.read<PerformanceMonitorService>(),
            playbookService: context.read<PlaybookAutomationPort>(),
            ragService: context.read<app_core.RagCapability>(),
            appSettings: appSettings,
          );
        }
      } catch (_) {}
    }

    if (viewModel == null) {
      return const Scaffold(body: Center(child: SizedBox.shrink()));
    }

    return ChangeNotifierProvider<AiChatViewModel>.value(
      value: viewModel..loadInitialDraft(),
      child: _LlmChatScreenBody(
        active: active,
        onHistoryVisibilityChanged: onHistoryVisibilityChanged,
        initialText: initialText,
        webViewScreenBuilder: webViewScreenBuilder,
      ),
    );
  }
}

class _LlmChatScreenBody extends StatefulWidget {
  final bool active;
  final ValueChanged<bool>? onHistoryVisibilityChanged;
  final String? initialText;
  final AiWebViewScreenBuilder? webViewScreenBuilder;

  const _LlmChatScreenBody({
    required this.active,
    this.onHistoryVisibilityChanged,
    this.initialText,
    this.webViewScreenBuilder,
  });

  @override
  State<_LlmChatScreenBody> createState() => _LlmChatScreenBodyState();
}

extension AiMessageActionStrings on AiStrings {
  String get saveAndSend =>
      language == AppLanguage.en ? 'Save & Send' : '保存并发送';
  String get editMessage => language == AppLanguage.en ? 'Edit' : '编辑消息';
  String get messageContent => language == AppLanguage.en ? 'Content' : '消息内容';
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
      language == AppLanguage.en ? 'No default' : '不指定默认服务器';
  String get quickSkill =>
      language == AppLanguage.en ? 'Use Skill' : '临时 Skill';
  String get quickSkillActive =>
      language == AppLanguage.en ? 'Skill Active' : 'Skill 已启用';
  String get noQuickSkill =>
      language == AppLanguage.en ? 'None' : '不启用临时 Skill';
  String get noSkills =>
      language == AppLanguage.en ? 'No custom skills' : '还没有自定义 Skills';
}

extension AiRunStatusStrings on AiStrings {
  String get assistantPreparing =>
      language == AppLanguage.en ? 'Preparing...' : '模型正在准备回答...';
  String get assistantThinking =>
      language == AppLanguage.en ? 'Thinking...' : '模型正在思考...';
  String get assistantResponding =>
      language == AppLanguage.en ? 'Responding...' : '正在输出回答...';
  String get assistantProcessingToolResult =>
      language == AppLanguage.en ? 'Processing result...' : '正在处理工具结果...';
  String get assistantProcessingApproval =>
      language == AppLanguage.en ? 'Processing approval...' : '正在处理审批结果...';
  String get assistantCollaborating =>
      language == AppLanguage.en ? 'Collaborating...' : '正在协调多 Agent 协作...';

  String get assistantToolBudgetExtended => language == AppLanguage.en
      ? 'Budget extended.'
      : '工具预算已扩展，请留意工具调用是否合理...';
  String get assistantToolBudgetAudit =>
      language == AppLanguage.en ? 'Auditing tool...' : '继续前正在审计工具调用...';
  String get assistantToolBudgetStopped => language == AppLanguage.en
      ? 'Tool blocked by audit.'
      : '安全审计后已停止继续调用工具...';

  String assistantRunningTool(String toolName) {
    final name = toolName.trim();
    if (language == AppLanguage.en) {
      return name.isEmpty ? 'Running tool...' : 'Running $name...';
    }
    return name.isEmpty ? '正在调用工具...' : '正在调用工具：$name';
  }

  String assistantAwaitingApproval(String serverName) {
    final name = serverName.trim();
    if (language == AppLanguage.en) {
      return name.isEmpty
          ? 'Waiting for tool approval...'
          : 'Awaiting approval ($name)...';
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
  double _historyAnimationTarget = 0;
  final ValueNotifier<double> _historyPanelProgress = ValueNotifier(0);
  bool _historyVisible = false;
  bool _toolsExpanded = false;
  bool _planApprovalUiInFlight = false;
  bool _newChatInFlight = false;
  bool _settingsOpening = false;
  int _settingsPresentationEpoch = 0;
  final ValueNotifier<bool> _isUserAtBottom = ValueNotifier(true);
  bool _scrollToBottomScheduled = false;
  bool _pendingScrollJump = false;
  StreamSubscription? _scrollSubscription;
  AiChatViewModel? _observedViewModel;
  String? _composerChatId;
  final Map<String, String> _chatDrafts = <String, String>{};

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
    _historySlideController =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 240),
          )
          ..addListener(() {
            final animation = _historySlideAnimation;
            if (animation == null || !mounted) return;
            _setHistoryPanelProgress(animation.value);
          })
          ..addStatusListener((status) {
            if (status != AnimationStatus.completed || !mounted) return;
            _historyPanelProgress.value = _historyAnimationTarget;
            if (_historyAnimationTarget <= 0.001) {
              _setHistoryVisibility(false);
            }
          });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final viewModel = context.read<AiChatViewModel>();
      _observedViewModel = viewModel;
      _composerChatId = viewModel.activeChatId;
      final initialChatId = _composerChatId;
      if (initialChatId != null && _inputController.text.isNotEmpty) {
        _chatDrafts[initialChatId] = _inputController.text;
      }
      viewModel.addListener(_onChatViewModelChanged);
      _scrollSubscription = viewModel.scrollRequests.listen((_) {
        _scrollToBottom();
      });
    });
  }

  @override
  void didUpdateWidget(covariant _LlmChatScreenBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) {
      _settingsPresentationEpoch += 1;
    }
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
    _observedViewModel?.removeListener(_onChatViewModelChanged);
    _historySlideController.dispose();
    _historyPanelProgress.dispose();
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
    if (_inputController.text.trim().isNotEmpty) return;
    try {
      final viewModel = context.read<AiChatViewModel>();
      final prompt = viewModel.checkPendingDiagnosticPrompt();
      if (prompt != null) {
        _inputController.text = prompt;
      }
    } catch (_) {}
  }

  void _onChatViewModelChanged() {
    final viewModel = _observedViewModel;
    if (!mounted || viewModel == null) return;
    final nextChatId = viewModel.activeChatId;
    final liveChatIds = viewModel.chats.map((chat) => chat.id).toSet();
    _chatDrafts.removeWhere((chatId, _) => !liveChatIds.contains(chatId));
    if (nextChatId == _composerChatId) return;

    final previousChatId = _composerChatId;
    if (previousChatId != null && liveChatIds.contains(previousChatId)) {
      _chatDrafts[previousChatId] = _inputController.text;
    } else if (previousChatId == null &&
        nextChatId != null &&
        _inputController.text.isNotEmpty) {
      // The initial draft can arrive before the async chat bootstrap assigns
      // an active chat. Attach it to that first chat instead of clearing it.
      _chatDrafts.putIfAbsent(nextChatId, () => _inputController.text);
    }
    _composerChatId = nextChatId;
    final nextText = nextChatId == null ? '' : _chatDrafts[nextChatId] ?? '';
    if (_inputController.text == nextText) return;
    _inputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  void _onInputFocusChanged() {
    if (_inputFocusNode.hasFocus) {
      if (_toolsExpanded &&
          usesCompactRailForHeight(MediaQuery.sizeOf(context).height)) {
        setState(() => _toolsExpanded = false);
      }
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
    final mediaQuery = MediaQuery.of(context);
    final compactKeyboardLayout = usesCompactKeyboardLayoutFor(
      viewportHeight: mediaQuery.size.height,
      keyboardInset: mediaQuery.viewInsets.bottom,
    );

    return ChatHistoryBackScope(
      historyVisible: _historyVisible,
      onCloseHistory: _closeHistoryPanel,
      child: Selector<AiChatViewModel, _ChatShellSnapshot>(
        selector: (context, vm) => _ChatShellSnapshot(
          loading: vm.loading,
          initialDraftFailed: vm.initialDraftFailed,
          hasActiveChat: vm.activeChat != null,
          activeChatId: vm.activeChatId,
        ),
        builder: (context, snapshot, child) {
          if (snapshot.loading) {
            return Scaffold(
              body: AppPageSurface(
                child: _ChatConversationSkeleton(strings: strings),
              ),
            );
          }
          if (snapshot.initialDraftFailed || !snapshot.hasActiveChat) {
            return Scaffold(
              body: AppPageSurface(
                child: AppEmptyState(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: strings.chatBootstrapFailedTitle,
                  message: strings.chatBootstrapFailedMessage,
                  action: SizedBox(
                    key: const ValueKey('chat-bootstrap-retry'),
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: () =>
                          context.read<AiChatViewModel>().retryInitialDraft(),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(strings.retry),
                    ),
                  ),
                ),
              ),
            );
          }

          return Scaffold(
            body: AppPageSurface(
              child: LayoutBuilder(
                builder: (context, bodyConstraints) {
                  final compactBodyLayout =
                      compactKeyboardLayout || bodyConstraints.maxHeight < 360;
                  return Stack(
                    children: [
                      Column(
                        children: [
                          if (!compactBodyLayout)
                            _ChatHeader(
                              onShowHistory: () =>
                                  _showHistory(context, strings),
                              onNewChat: () => unawaited(_createNewChat()),
                              newChatInFlight: _newChatInFlight,
                              onShowSettings: () => _showSettings(strings),
                              settingsOpening: _settingsOpening,
                            ),
                          Expanded(
                            child: Stack(
                              children: [
                                _ChatMessageList(
                                  scrollController: _scrollController,
                                  onUserScroll: _updateUserScrollPosition,
                                  onSuggestionSelected: _selectSuggestedPrompt,
                                  onEditUser: (index) =>
                                      _editUserMessage(index, strings),
                                  onRegenerate: (index) =>
                                      _confirmRegenerateAssistant(
                                        index,
                                        strings,
                                      ),
                                  onBranch: (index) =>
                                      _confirmBranchFromAssistant(
                                        index,
                                        strings,
                                      ),
                                  onContinueTimeout: () =>
                                      _continueAfterTimeout(strings),
                                  onRevisePlan: (chat) =>
                                      _revisePlan(chat, strings),
                                ),
                                ChatJumpToBottomButton(
                                  scrollController: _scrollController,
                                  isUserAtBottom: _isUserAtBottom,
                                  onPressed: () => _scrollToBottom(jump: true),
                                  strings: strings,
                                ),
                              ],
                            ),
                          ),
                          _ChatPlanApprovalArea(
                            availableHeight: bodyConstraints.maxHeight,
                            availableWidth: bodyConstraints.maxWidth,
                            inputController: _inputController,
                            toolsExpanded: _toolsExpanded,
                            uiBusy: _planApprovalUiInFlight,
                            onApprove: approvePlanAndExecute,
                            onRevise: (chat) => _revisePlan(chat, strings),
                          ),
                          const _ChatToolApprovalArea(),
                          SafeArea(
                            top: false,
                            child: _ChatComposer(
                              availableHeight: bodyConstraints.maxHeight,
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
                      _ChatHistoryOverlay(strings: strings),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
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
    return strings.selectedServers(viewModel.selectedConnectionIds.length);
  }

  void _selectSuggestedPrompt(String prompt) {
    _inputController.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _inputFocusNode.requestFocus();
  }

  Future<void> _createNewChat() async {
    if (_newChatInFlight) return;
    final requestedFromChatId = _composerChatId;
    setState(() => _newChatInFlight = true);
    final viewModel = context.read<AiChatViewModel>();
    try {
      final model = await viewModel.loadNewChatModel();
      if (!mounted) return;
      if (_composerChatId != requestedFromChatId) return;
      final currentChatId = _composerChatId;
      if (currentChatId != null) {
        _chatDrafts[currentChatId] = _inputController.text;
      }
      final preserveChatIds = _chatDrafts.entries
          .where((entry) => entry.value.isNotEmpty)
          .map((entry) => entry.key)
          .toSet();
      final created = viewModel.createChat(
        model,
        preserveChatIds: preserveChatIds,
      );
      if (!created && mounted) {
        final strings = AiStrings(context.read<AppSettings>().language);
        LlmChatCommandsHelper.showCommandFeedback(context, strings.newChatBusy);
      }
    } catch (_, stackTrace) {
      AppLogService.instance.error(
        'Failed to create AI chat draft',
        stackTrace: stackTrace,
      );
      if (mounted) {
        final strings = AiStrings(context.read<AppSettings>().language);
        LlmChatCommandsHelper.showCommandFeedback(
          context,
          strings.newChatCreateFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _newChatInFlight = false);
      } else {
        _newChatInFlight = false;
      }
    }
  }

  Future<void> _revisePlan(AiChatRecord chat, AiStrings strings) async {
    final enabled = await LlmChatCommandsHelper.setPlanModeFromUi(
      context: context,
      chat: chat,
      enabled: true,
      strings: strings,
    );
    if (!mounted || !enabled) return;
    if (_inputController.text.trim().isEmpty) {
      _inputController.value = TextEditingValue(
        text: strings.planRevisionPrompt,
        selection: TextSelection.collapsed(
          offset: strings.planRevisionPrompt.length,
        ),
      );
    }
    _inputFocusNode.requestFocus();
    _scrollToBottom(jump: false);
  }

  Future<void> _selectTargetServer(AiStrings strings) async {
    final viewModel = context.read<AiChatViewModel>();
    if (viewModel.connections.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.noConfiguredServers)));
      }
      return;
    }

    final result = await showTargetServerPickerSheet(
      context: context,
      connections: List<ConnectionConfig>.unmodifiable(viewModel.connections),
      initialSelection: viewModel.selectedConnectionIds,
      strings: strings,
    );

    if (!mounted) return;
    if (result != null) {
      viewModel.updateSelectedConnections(result);
    }
  }

  Future<void> _openClientWebView(String chatId) async {
    final builder = widget.webViewScreenBuilder;
    if (builder == null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const _AiWebViewUnavailableScreen(),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) {
          return builder(routeContext, chatId);
        },
      ),
    );
  }

  Future<void> _showPromptCustomizer(AiStrings strings) async {
    final viewModel = context.read<AiChatViewModel>();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChangeNotifierProvider<AiChatViewModel>.value(
        value: viewModel,
        child: PromptCustomizerDialog(strings: strings),
      ),
    );
  }

  KeyEventResult _handleInputKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopPlatform || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
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

  Future<void> _showSettings(AiStrings strings) async {
    if (_settingsOpening || !mounted || !widget.active) return;
    final presentationEpoch = _settingsPresentationEpoch;
    setState(() => _settingsOpening = true);
    try {
      AiChatViewModel? viewModel;
      _PendingAiSettings? nextSettings;
      try {
        viewModel = context.read<AiChatViewModel>();
        final settingsData = await viewModel.loadLlmSettingsData();
        final settings = settingsData['settings'] as AiConnectionSettings;
        final cachedModels = settingsData['cachedModels'] as List<String>;
        final baseUrlHistory = settingsData['baseUrlHistory'] as List<String>;
        final apiKeyHistory =
            settingsData['apiKeyHistory'] as List<AiApiKeyHistoryEntry>;

        if (!mounted || !_isSettingsPresentationCurrent(presentationEpoch)) {
          return;
        }
        viewModel.logLlmSettingsOpened(settings);
        nextSettings = await Navigator.of(context).push<_PendingAiSettings>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => ChangeNotifierProvider<AiChatViewModel>.value(
              value: viewModel!,
              child: LlmSettingsScreen(
                initialSettings: settings,
                initialModels: buildInitialModelOptions(
                  currentModel: settings.model,
                  cachedModels: cachedModels,
                ),
                initialBaseUrlHistory: baseUrlHistory,
                initialApiKeyHistory: apiKeyHistory,
              ),
            ),
          ),
        );
      } catch (_, stackTrace) {
        AppLogService.instance.error(
          'Failed to open LLM settings',
          stackTrace: stackTrace,
        );
        _showSettingsFailure(strings.settingsOpenFailed, presentationEpoch);
        return;
      }

      if (nextSettings == null) return;
      if (!mounted) return;
      try {
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
        // Reload VM draft values.
        await viewModel.loadInitialDraft();
      } catch (_, stackTrace) {
        AppLogService.instance.error(
          'Failed to apply saved LLM settings',
          stackTrace: stackTrace,
        );
        _showSettingsFailure(strings.settingsApplyFailed, presentationEpoch);
      }
    } finally {
      if (mounted) setState(() => _settingsOpening = false);
    }
  }

  bool _isSettingsPresentationCurrent(int presentationEpoch) {
    return widget.active && presentationEpoch == _settingsPresentationEpoch;
  }

  void _showSettingsFailure(String message, int presentationEpoch) {
    if (!mounted || !_isSettingsPresentationCurrent(presentationEpoch)) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _showHistory(BuildContext context, AiStrings strings) async {
    _openHistoryPanel();
    final viewModel = context.read<AiChatViewModel>();
    unawaited(viewModel.loadHistoryChatsIfNeeded());
  }

  void _openHistoryPanel() {
    final viewModel = context.read<AiChatViewModel>();
    _setHistoryVisibility(true);
    _animateHistoryPanel(1);
    unawaited(viewModel.loadHistoryChatsIfNeeded());
  }

  void _closeHistoryPanel() {
    _animateHistoryPanel(0);
  }

  void _animateHistoryPanel(double target) {
    final safeTarget = target.clamp(0.0, 1.0);
    _historyAnimationTarget = safeTarget;
    _historySlideAnimation =
        Tween<double>(
          begin: _historyPanelProgress.value.clamp(0.0, 1.0),
          end: safeTarget,
        ).animate(
          CurvedAnimation(
            parent: _historySlideController,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        );
    _historySlideController.forward(from: 0);
  }

  void _setHistoryPanelProgress(double progress) {
    final normalizedProgress = progress.clamp(0.0, 1.0);
    if ((_historyPanelProgress.value - normalizedProgress).abs() < 0.001) {
      return;
    }
    _historyPanelProgress.value = normalizedProgress;
    if (normalizedProgress <= 0.001) _setHistoryVisibility(false);
  }

  void _setHistoryVisibility(bool visible) {
    if (_historyVisible == visible) return;
    setState(() => _historyVisible = visible);
    widget.onHistoryVisibilityChanged?.call(visible);
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
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

class _ChatConversationSkeleton extends StatelessWidget {
  const _ChatConversationSkeleton({required this.strings});

  final AiStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppSkeletonizer(
      enabled: true,
      semanticsLabel: strings.title,
      child: Column(
        children: [
          // 1. Header Bar (1:1 with _ChatHeader)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
            child: Row(
              children: [
                IconButton(
                  tooltip: strings.history,
                  icon: const Icon(Icons.menu_rounded),
                  style: IconButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                    backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
                  ),
                  onPressed: null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        strings.newChat,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                      ),
                      Text(
                        '0 / 128K (0.0%)',
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: strings.newChat,
                  icon: const Icon(Icons.add_comment_outlined),
                  onPressed: null,
                ),
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    tooltip: strings.settings,
                    icon: const Icon(Icons.tune_rounded),
                    onPressed: null,
                  ),
                ),
              ],
            ),
          ),

          // 2. Message / Welcome Area (1:1 with _ChatMessageList empty state)
          Expanded(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 280),
                  child: AppEmptyState(
                    icon: Icons.auto_awesome_rounded,
                    title: strings.welcomeTitle,
                    message: strings.welcome,
                    compact: true,
                    contained: false,
                    action: _ChatStarterSuggestions(
                      strings: strings,
                      onSelected: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 3. Bottom Composer (1:1 with _ChatComposer)
          SafeArea(
            top: false,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.96),
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outline.withValues(alpha: 0.56),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusMedium,
                        ),
                        border: Border.all(
                          color: colorScheme.outline.withValues(alpha: 0.62),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: strings.tools,
                            style: IconButton.styleFrom(
                              minimumSize: const Size.square(48),
                              foregroundColor: colorScheme.primary,
                            ),
                            icon: const Icon(Icons.add_rounded),
                            onPressed: null,
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              child: Text(
                                strings.composerHint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(
                              right: 8,
                              top: 6,
                              bottom: 6,
                              left: 4,
                            ),
                            child: IconButton(
                              tooltip: strings.send,
                              style: IconButton.styleFrom(
                                minimumSize: const Size.square(38),
                                padding: EdgeInsets.zero,
                                foregroundColor: colorScheme.onPrimary,
                                backgroundColor: colorScheme.primary,
                              ),
                              icon: const Icon(Icons.arrow_upward_rounded),
                              onPressed: null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
