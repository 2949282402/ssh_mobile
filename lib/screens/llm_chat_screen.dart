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
import '../services/ai_tool_service.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/client_webview_service.dart';
import '../services/llm_chat_service.dart';
import '../services/multi_agent_coordinator.dart';
import '../services/performance_monitor_service.dart';
import '../services/performance_monitor_tool_service.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/playbook_service.dart';
import '../services/rag_service.dart';
import '../utils/text_chunker.dart';
import '../widgets/overflow_scroll_text.dart';
import '../widgets/glass_container.dart';

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

const List<String> _defaultModels = [
  'deepseek-v4-flash',
  'deepseek-v4-pro',
];

class _ToolOption {
  final String name;
  final String description;

  const _ToolOption({
    required this.name,
    required this.description,
  });
}

@visibleForTesting
List<String> resolveFetchedModelOptions({
  required Iterable<String> fetchedModels,
  required Iterable<String> fallbackModels,
}) {
  final normalizedFetched = fetchedModels
      .map((model) => model.trim())
      .where((model) => model.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
  if (normalizedFetched.isNotEmpty) {
    return normalizedFetched;
  }

  return fallbackModels
      .map((model) => model.trim())
      .where((model) => model.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
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

class LlmChatScreen extends StatefulWidget {
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
    return _LlmChatScreenState.buildMultipartContent(textContent, attachments);
  }

  @override
  State<LlmChatScreen> createState() => _LlmChatScreenState();
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

class _LlmChatScreenState extends State<LlmChatScreen>
    with
        AutomaticKeepAliveClientMixin<LlmChatScreen>,
        SingleTickerProviderStateMixin {
  static const double _scrollBottomDistance = 48;
  final TextEditingController _inputController = TextEditingController();
  late final FocusNode _inputFocusNode;
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _historySlideController;
  Animation<double>? _historySlideAnimation;
  final ValueNotifier<double> _historyPanelExtent = ValueNotifier(0);
  List<AiChatRecord> _chats = const [];
  List<AiChatRecord> _savedHistoryChats = const [];
  String? _activeChatId;
  _PendingToolApproval? _pendingApproval;
  LlmCancellationToken? _activeCancellationToken;
  int _contextWindowTokens = AiContextWindowSize.k259;
  bool _loading = true;
  bool _settingsLoadStarted = false;
  bool _historyLoadStarted = false;
  bool _historyLoading = false;
  bool _sending = false;
  bool _toolsExpanded = false;
  bool _isUserAtBottom = true;
  final Set<String> _selectedConnectionIds = {};
  final Map<String, Set<String>> _chatAllowedTools = {};
  final Set<String> _pendingForceCompressionChats = {};
  final List<AiChatAttachment> _pendingAttachments = [];
  String? _contextTokenCacheKey;
  String? _contextTokenCacheChatId;
  int _cachedContextTokens = 0;
  DateTime _lastContextTokenEstimateAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _scrollToBottomScheduled = false;
  bool _pendingScrollJump = false;
  final ValueNotifier<String> _streamingAssistantText =
      ValueNotifier<String>('');
  final ValueNotifier<String> _streamingAssistantStatus =
      ValueNotifier<String>('');
  _StreamingAssistantTarget? _streamingAssistantTarget;

  AiChatRecord? get _activeChat {
    for (final chat in _chats) {
      if (chat.id == _activeChatId) return chat;
    }
    return _chats.isEmpty ? null : _chats.first;
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
    return (metrics.maxScrollExtent - metrics.pixels) <= _scrollBottomDistance;
  }

  void _updateUserScrollPosition(ScrollMetrics metrics) {
    _setUserAtBottom(_isNearBottom(metrics));
  }

  bool _shouldShowJumpToBottomButton() {
    if (!_sending) return false;
    if (!_scrollController.hasClients) return false;
    if (_isUserAtBottom) return false;
    if (_scrollController.position.maxScrollExtent <= _scrollBottomDistance) {
      return false;
    }
    return true;
  }

  void _checkPendingDiagnosticPrompt() {
    try {
      final playbookService = context.read<PlaybookService>();
      if (playbookService.pendingDiagnosticPrompt != null) {
        _inputController.text = playbookService.pendingDiagnosticPrompt!;
        playbookService.pendingDiagnosticPrompt = null;
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _inputController.text = widget.initialText!;
    }
    _checkPendingDiagnosticPrompt();
    _inputFocusNode = FocusNode(onKeyEvent: _handleInputKeyEvent);
    _historySlideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        final animation = _historySlideAnimation;
        if (animation == null || !mounted) return;
        _setHistoryPanelExtent(animation.value);
      });
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadInitialDraft();
      });
    }
  }

  @override
  void didUpdateWidget(covariant LlmChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_settingsLoadStarted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadInitialDraft();
      });
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
    if (_pendingApproval?.completer.isCompleted == false) {
      _pendingApproval!.completer.complete(
        const AiToolApprovalDecision.rejected(),
      );
    }
    _activeCancellationToken?.cancel();
    _historySlideController.dispose();
    _historyPanelExtent.dispose();
    _streamingAssistantText.dispose();
    _streamingAssistantStatus.dispose();
    _inputFocusNode.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialDraft() async {
    if (_settingsLoadStarted) return;
    _settingsLoadStarted = true;
    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!mounted) return;
    setState(() {
      final draft = _newChatRecord(settings.model);
      _chats = [draft];
      _activeChatId = draft.id;
      _contextWindowTokens = settings.contextWindowTokens;
      _loading = false;
    });
  }

  Future<void> _loadHistoryChatsIfNeeded() async {
    if (_historyLoadStarted || _historyLoading) return;
    setState(() => _historyLoading = true);
    final chats = await context.read<StorageService>().loadAiChats();
    if (!mounted) return;
    setState(() {
      _historyLoadStarted = true;
      _historyLoading = false;
      _savedHistoryChats = chats;
      final drafts = _chats.where((chat) => chat.messages.isEmpty).toList();
      final draftIds = drafts.map((chat) => chat.id).toSet();
      _chats = [
        ...drafts,
        ...chats.where((chat) => !draftIds.contains(chat.id)),
      ];
      _activeChatId ??= _chats.isEmpty ? null : _chats.first.id;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _AiStrings(language);
    final colorScheme = Theme.of(context).colorScheme;
    final activeChat = _activeChat;

    if (_loading || activeChat == null) {
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
    final contextTokens = _contextTokensFor(activeChat);
    final contextPercent =
        _contextWindowTokens <= 0 ? 0.0 : contextTokens / _contextWindowTokens;

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
                      // Keyed builders make chat switches perceptible without
                      // replacing the stable toolbar or input controls.
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
                            Text(
                              activeChat.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              _contextUsage(
                                contextTokens,
                                _contextWindowTokens,
                                contextPercent,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                      onPressed:
                          _sending ? null : () => _createChatFromSettings(),
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
                // Avoid AnimatedSwitcher here: it would briefly mount two
                // ListViews that share the same ScrollController.
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
                            _streamingTextFor(activeChat.id, message);
                        final streamingStatusListenable =
                            _streamingStatusFor(activeChat.id, message);
                        return RepaintBoundary(
                          key: ValueKey(
                            '${message.role}-${message.createdAt.microsecondsSinceEpoch}',
                          ),
                          child: _MessageBubble(
                            message: message,
                            streamingTextListenable: streamingTextListenable,
                            streamingStatusListenable:
                                streamingStatusListenable,
                            canAct: !_sending &&
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
              if (_pendingApproval?.chatId == activeChat.id)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height < 700
                        ? MediaQuery.sizeOf(context).height * 0.52
                        : 420,
                  ),
                  child: _ToolApprovalPanel(
                    pending: _pendingApproval!,
                    strings: strings,
                    onApprove: () => _resolvePendingApproval(approved: true),
                    onReject: () => _resolvePendingApproval(approved: false),
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
                        if (_shouldShowSlashCommandPanel)
                          _buildSlashCommandPanel(context, strings),
                        if (_pendingAttachments.isNotEmpty)
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
                              tooltip: _sending ? strings.stop : strings.send,
                              icon: Icon(
                                _sending
                                    ? Icons.stop_rounded
                                    : Icons.send_rounded,
                              ),
                              onPressed: _sending
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
    if (_selectedConnectionIds.isEmpty) return strings.serverTarget;
    if (_selectedConnectionIds.length == 1) {
      final id = _selectedConnectionIds.first;
      final connection = context.read<StorageService>().getConnection(id);
      return connection == null ? strings.serverTarget : connection.name;
    }
    return strings.language == AppLanguage.en
        ? '${_selectedConnectionIds.length} Servers'
        : '${_selectedConnectionIds.length} 台服务器';
  }

  Future<void> _selectTargetServer(_AiStrings strings) async {
    final storage = context.read<StorageService>();
    if (storage.connections.isEmpty) {
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

    final selected = Set<String>.from(_selectedConnectionIds);
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
                          for (final connection in storage.connections)
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
      setState(() {
        _selectedConnectionIds.clear();
        _selectedConnectionIds.addAll(result);
      });
    }
  }

  Future<void> _openClientWebView(String chatId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClientWebViewScreen(chatId: chatId),
      ),
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

  Future<void> _showHistory(BuildContext context, _AiStrings strings) async {
    _openHistoryPanel(context);
    unawaited(_loadHistoryChatsIfNeeded());
  }

  double _historyPanelWidth(BuildContext context) {
    return MediaQuery.sizeOf(context).width;
  }

  void _openHistoryPanel(BuildContext context) {
    _animateHistoryPanel(context, _historyPanelWidth(context));
    unawaited(_loadHistoryChatsIfNeeded());
  }

  void _closeHistoryPanel(BuildContext context) {
    _animateHistoryPanel(context, 0);
  }

  void _animateHistoryPanel(BuildContext context, double target) {
    final width = _historyPanelWidth(context);
    final safeTarget = target.clamp(0.0, width);
    _historySlideAnimation = Tween<double>(
      begin: _historyPanelExtent.value.clamp(0.0, width),
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

  void _setHistoryPanelExtent(double extent) {
    if ((_historyPanelExtent.value - extent).abs() < 0.5) return;
    final wasVisible = _historyPanelExtent.value > 0.5;
    _historyPanelExtent.value = extent;
    final isVisible = extent > 0.5;
    if (wasVisible != isVisible) {
      widget.onHistoryVisibilityChanged?.call(isVisible);
    }
  }

  Widget _buildHistoryOverlay(BuildContext context, _AiStrings strings) {
    final width = _historyPanelWidth(context);
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: _historyPanelExtent,
      builder: (context, rawExtent, _) {
        final extent = rawExtent.clamp(0.0, width);
        if (extent <= 0.5) return const SizedBox.shrink();
        final progress = width == 0 ? 0.0 : extent / width;
        return Positioned.fill(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => _closeHistoryPanel(context),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.28 * progress),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                left: extent - width,
                width: width,
                child: SafeArea(
                  child: GlassmorphicContainer(
                    borderRadius: 0,
                    blurX: 16,
                    blurY: 16,
                    backgroundColor:
                        colorScheme.surface.withValues(alpha: 0.72),
                    borderColor: colorScheme.outlineVariant,
                    borderWidth: 1,
                    child: _HistoryPanel(
                      chats: _savedHistoryChats,
                      activeChatId: _activeChatId,
                      loading: _historyLoading,
                      strings: strings,
                      formatTime: _formatTime,
                      onClose: () => _closeHistoryPanel(context),
                      onNewChat: () {
                        _closeHistoryPanel(context);
                        _createChatFromSettings();
                      },
                      onDeleteChat: (chatId) async {
                        await _deleteChat(chatId);
                      },
                      onSelectChat: (chatId) {
                        final selected = _chatById(chatId);
                        setState(() {
                          if (selected != null &&
                              !_chats.any((chat) => chat.id == selected.id)) {
                            _chats = [
                              selected,
                              ..._chats
                                  .where((chat) => chat.messages.isNotEmpty),
                              ..._chats.where((chat) => chat.messages.isEmpty),
                            ];
                          }
                          _activeChatId = chatId;
                        });
                        _closeHistoryPanel(context);
                        _scrollToBottom();
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSettings(BuildContext context, _AiStrings strings) async {
    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    final cachedModels = await storage.loadCachedAiModels(
      baseUrl: settings.baseUrl,
    );
    final baseUrlHistory = await storage.loadAiBaseUrlHistory();
    final apiKeyHistory = await storage.loadAiApiKeyHistory();
    if (!context.mounted) return;
    AppLogService.instance.info(
      'LLM settings page opened',
      details:
          'baseUrl=${settings.baseUrl} model=${settings.model} hasApiKey=${settings.hasApiKey}',
    );

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
      setState(() => _contextWindowTokens = nextSettings.contextWindowTokens);
      final activeChat = _activeChat;
      final nextModel = nextSettings.model.trim();
      if (activeChat != null &&
          nextModel.isNotEmpty &&
          activeChat.model != nextModel) {
        final updatedChat = activeChat.copyWith(
          model: nextModel,
          updatedAt: DateTime.now(),
        );
        if (activeChat.messages.isEmpty) {
          setState(() => _replaceChat(updatedChat));
        } else {
          await _updateActiveChat(updatedChat);
        }
      }
      return;
    }
  }

  Future<void> _createChatFromSettings() async {
    final settings =
        await context.read<StorageService>().loadAiConnectionSettings();
    if (!mounted) return;
    _createChat(settings.model);
  }

  void _createChat(String model) {
    final chat = _newChatRecord(model);
    setState(() {
      _chats = [
        chat,
        ..._chats.where((item) => item.messages.isNotEmpty),
      ];
      _activeChatId = chat.id;
    });
    _scrollToBottom();
  }

  Future<void> _deleteChat(String id) async {
    if (_chats.isEmpty && _savedHistoryChats.isEmpty) return;
    final storage = context.read<StorageService>();
    final deleted = _chatById(id);
    _chatAllowedTools.remove(id);
    _pendingForceCompressionChats.remove(id);
    final nextChats = _chats.where((chat) => chat.id != id).toList();
    if (nextChats.isEmpty) {
      final settings = await storage.loadAiConnectionSettings();
      if (!mounted) return;
      nextChats.add(_newChatRecord(settings.model));
    }
    setState(() {
      _chats = nextChats;
      _savedHistoryChats =
          _savedHistoryChats.where((chat) => chat.id != id).toList();
      if (_activeChatId == id || _activeChatId == null) {
        _activeChatId = nextChats.first.id;
      }
    });
    if (deleted?.messages.isNotEmpty == true) {
      await storage.deleteAiChat(id);
    }
    ClientWebViewService.instance.clearSession(id);
    _scrollToBottom(jump: true);
  }

  Future<void> _updateActiveChat(AiChatRecord chat) async {
    setState(() => _replaceChat(chat));
    await context.read<StorageService>().saveAiChat(chat);
  }

  void _replaceChat(AiChatRecord chat, {bool sort = true}) {
    _chats = sort
        ? upsertAiChatRecordsByUpdatedAt(_chats, chat)
        : _replaceChatWithoutReordering(_chats, chat);
    if (chat.messages.isNotEmpty) {
      _savedHistoryChats = sort && _historyLoadStarted
          ? upsertAiChatRecordsByUpdatedAt(_savedHistoryChats, chat)
          : _replaceChatWithoutReordering(
              _savedHistoryChats,
              chat,
              insertIfMissing: false,
            );
    }
    _activeChatId = chat.id;
  }

  List<AiChatRecord> _replaceChatWithoutReordering(
    List<AiChatRecord> chats,
    AiChatRecord chat, {
    bool insertIfMissing = true,
  }) {
    final next = [...chats];
    final index = next.indexWhere((item) => item.id == chat.id);
    if (index >= 0) {
      next[index] = chat;
    } else if (insertIfMissing) {
      // Streaming and trace updates can hit this path often; keep the chat in
      // place instead of resorting the whole list on every partial change.
      next.insert(0, chat);
    }
    return next;
  }

  AiChatRecord? _chatById(String id) {
    for (final chat in _chats) {
      if (chat.id == id) return chat;
    }
    for (final chat in _savedHistoryChats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  AiChatRecord _newChatRecord(String model) {
    final now = DateTime.now();
    return AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: _AiStrings(context.read<AppSettings>().language).newChat,
      model: model,
      messages: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  List<String> _modelOptions(String model) {
    return {..._defaultModels, if (model.trim().isNotEmpty) model.trim()}
        .toList()
      ..sort();
  }

  String _titleFrom(String text, _AiStrings strings) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return strings.newChat;
    return cleaned.length > 22 ? '${cleaned.substring(0, 22)}...' : cleaned;
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  List<Map<String, dynamic>> _messagesForRequest(
    List<AiChatMessageRecord> messages, {
    AiChatMessageRecord? placeholder,
  }) {
    return messages
        .where((message) => message.role != 'error')
        .where((message) => message != placeholder)
        .map((message) {
          final textContent = _contextContentFor(message);
          if (textContent.trim().isEmpty && message.attachments.isEmpty) {
            return null;
          }
          final role = message.role == 'user' ? 'user' : 'assistant';
          if (message.role == 'user' && message.attachments.isNotEmpty) {
            return <String, dynamic>{
              'role': role,
              'content':
                  buildMultipartContent(textContent, message.attachments),
            };
          }
          return <String, dynamic>{
            'role': role,
            'content': textContent,
          };
        })
        .nonNulls
        .toList();
  }

  static List<Map<String, dynamic>> buildMultipartContent(
    String textContent,
    List<AiChatAttachment> attachments,
  ) {
    final textWithFiles = StringBuffer(textContent);
    for (final attachment in attachments) {
      if (!attachment.isImage) {
        if (attachment.isTextFile && attachment.dataBase64.isNotEmpty) {
          try {
            final decoded = utf8.decode(base64Decode(attachment.dataBase64));
            textWithFiles.write('\n\n[File: ${attachment.fileName}]\n$decoded');
          } catch (_) {
            textWithFiles.write(
              '\n\n[Attached file: ${attachment.fileName} (${_formatAttachmentSize(attachment.sizeBytes)})]',
            );
          }
        } else {
          textWithFiles.write(
            '\n\n[Attached file: ${attachment.fileName} (${_formatAttachmentSize(attachment.sizeBytes)})]',
          );
        }
      }
    }
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': textWithFiles.toString()},
    ];
    for (final attachment in attachments) {
      if (attachment.isImage && attachment.dataBase64.isNotEmpty) {
        parts.add({
          'type': 'image_url',
          'image_url': {
            'url':
                'data:${attachment.mimeType};base64,${attachment.dataBase64}',
          },
        });
      }
    }
    return parts;
  }

  static String _formatAttachmentSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  String _contextContentFor(AiChatMessageRecord message) {
    if (message.role == 'user' && message.contextText != null) {
      return message.contextText!;
    }
    if (message.role == 'assistant') {
      return message.contextText ??
          _contextTextForAssistant(message.text, traces: message.traces);
    }
    return message.text;
  }

  Future<String?> _contextTextForUser(
    String text, {
    List<RagChunk> ragChunks = const [],
  }) async {
    final lines = <String>[];
    if (_selectedConnectionIds.isNotEmpty) {
      final storage = context.read<StorageService>();
      final serverInfos = <String>[];
      for (final id in _selectedConnectionIds) {
        final connection = storage.getConnection(id);
        if (connection != null) {
          serverInfos.add(
            '- ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
          );
        }
      }
      if (serverInfos.isNotEmpty) {
        lines.add(
          'Target servers:\n${serverInfos.join('\n')}',
        );
      }
    }

    if (ragChunks.isNotEmpty) {
      final isEn = context.read<AppSettings>().isEnglish;
      final ragLines = <String>[];
      ragLines.add(isEn
          ? '【Ops Knowledge Base Reference Information】:'
          : '【运维知识库参考信息】：');
      for (final chunk in ragChunks) {
        ragLines.add('---');
        ragLines.add(isEn
            ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
            : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})');
        ragLines.add('${isEn ? 'Content' : '内容'}:\n${chunk.text}');
      }
      ragLines.add('---');
      lines.add(ragLines.join('\n'));
    }

    if (lines.isEmpty) return null;
    return '${lines.join('\n\n')}\n\nUser request:\n$text';
  }

  String _contextTextForAssistant(
    String text, {
    List<AiMessageTrace> traces = const [],
  }) {
    final trimmed = text.trim();
    final body = trimmed.isEmpty
        ? trimmed
        : !_shouldOmitAssistantBody(trimmed)
            ? trimmed
            : _slimAssistantBody(trimmed);
    if (traces.isEmpty) return body;

    final buffer = StringBuffer();
    if (body.isNotEmpty) {
      buffer.writeln(body);
      buffer.writeln();
    }
    buffer.writeln('Assistant execution memory:');
    for (final trace in traces) {
      buffer
        ..writeln('[${trace.kind}] ${trace.title}')
        ..writeln(_traceMemoryContent(trace))
        ..writeln();
    }
    return buffer.toString().trimRight();
  }

  String _traceMemoryContent(AiMessageTrace trace) {
    final trimmed = trace.content.trim();
    if (trimmed.length <= 2500) return trimmed;
    final preview =
        trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(900);
    return '[Large ${trace.kind} output omitted from future context. '
        'The full trace remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  String _slimAssistantBody(String trimmed) {
    final preview =
        trimmed.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(420);
    final type = _largeAssistantBodyType(trimmed);
    return '[Large $type output omitted from future context. '
        'The full content remains visible in chat history. '
        'Length: ${trimmed.length} chars. '
        'Preview: ${String.fromCharCodes(preview)}]';
  }

  bool _shouldOmitAssistantBody(String text) {
    final lowerText = text.toLowerCase();
    if (text.length > 6000) return true;
    if (text.length > 2500 && _codeFenceCount(text) >= 2) return true;
    if (text.length > 2500 &&
        (lowerText.contains('<html') || lowerText.contains('<!doctype'))) {
      return true;
    }
    if (text.length > 3000 && _markdownDocumentScore(text) >= 10) return true;
    return false;
  }

  String _largeAssistantBodyType(String text) {
    final lowerText = text.toLowerCase();
    if (lowerText.contains('<html') || lowerText.contains('<!doctype')) {
      return 'HTML';
    }
    if (_codeFenceCount(text) >= 2) return 'code/document';
    if (_markdownDocumentScore(text) >= 10) return 'Markdown/document';
    return 'document';
  }

  int _codeFenceCount(String text) {
    return RegExp(r'```').allMatches(text).length;
  }

  int _markdownDocumentScore(String text) {
    var score = 0;
    for (final line in text.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) score += 2;
      if (trimmed.startsWith('|')) score++;
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) score++;
      if (RegExp(r'^\d+\. ').hasMatch(trimmed)) score++;
    }
    return score;
  }

  int _contextTokensFor(AiChatRecord chat) {
    final key = _contextTokenKey(chat);
    if (_contextTokenCacheKey == key) return _cachedContextTokens;
    final now = DateTime.now();
    if (_sending &&
        _contextTokenCacheChatId == chat.id &&
        _contextTokenCacheKey != null &&
        now.difference(_lastContextTokenEstimateAt) <
            const Duration(milliseconds: 1500)) {
      return _cachedContextTokens;
    }
    _contextTokenCacheKey = key;
    _contextTokenCacheChatId = chat.id;
    _lastContextTokenEstimateAt = now;
    _cachedContextTokens = _estimatedContextTokens(chat.messages);
    return _cachedContextTokens;
  }

  String _contextTokenKey(AiChatRecord chat) {
    final messages = chat.messages;
    if (messages.isEmpty) return '${chat.id}:0';
    final last = messages.last;
    return [
      chat.id,
      messages.length,
      last.role,
      last.createdAt.microsecondsSinceEpoch,
      last.text.length,
      last.contextText?.length ?? 0,
      last.traces.length,
    ].join(':');
  }

  int _estimatedContextTokens(List<AiChatMessageRecord> messages) {
    // Keep this list dynamically typed because tool-call messages may later
    // carry non-string fields; otherwise Dart can infer Map<String, String>
    // and fail at runtime when inserting or spreading richer request objects.
    final mapped = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': 'system'},
      ..._messagesForRequest(messages),
    ];
    return LlmChatService.estimateMessagesTokens(mapped);
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

  ValueListenable<String>? _streamingTextFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return _streamingAssistantText;
  }

  ValueListenable<String>? _streamingStatusFor(
    String chatId,
    AiChatMessageRecord message,
  ) {
    final target = _streamingAssistantTarget;
    if (message.role != 'assistant' ||
        target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != message.createdAt) {
      return null;
    }
    return _streamingAssistantStatus;
  }

  @override
  bool get wantKeepAlive => true;
}
