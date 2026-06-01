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

part 'llm_chat/assistant_run_indicator.dart';
part 'llm_chat/llm_settings_screen.dart';
part 'llm_chat/message_bubble.dart';
part 'llm_chat/history_panel.dart';
part 'llm_chat/chat_tools_bar.dart';
part 'llm_chat/tool_approval_panel.dart';
part 'llm_chat/ai_strings.dart';

const List<String> _defaultModels = [
  'deepseek-v4-flash',
  'deepseek-v4-pro',
];

class _SlashCommandMeta {
  final String command;
  final String summary;
  final String details;

  const _SlashCommandMeta({
    required this.command,
    required this.summary,
    required this.details,
  });
}

class _ParsedSlashCommand {
  final String command;
  final String arguments;

  const _ParsedSlashCommand(this.command, this.arguments);
}

class _ToolOption {
  final String name;
  final String description;

  const _ToolOption({
    required this.name,
    required this.description,
  });
}

const List<_SlashCommandMeta> _defaultSlashCommands = [
  _SlashCommandMeta(
    command: '/compact',
    summary: 'Force compression on the next request.',
    details: 'The next AI request will compress context before sending.',
  ),
  _SlashCommandMeta(
    command: '/tools',
    summary: 'Limit tools for this chat.',
    details: 'Restrict which tools the model can call in the current chat.',
  ),
  _SlashCommandMeta(
    command: '/skills',
    summary: 'Open and manage local AI skills.',
    details: 'View saved Skills and enable or disable them.',
  ),
];

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
  final VoidCallback? onOpenSettingsDrawer;
  final String? initialText;

  const LlmChatScreen({
    super.key,
    this.active = true,
    this.onHistoryVisibilityChanged,
    this.onOpenSettingsDrawer,
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
                      tooltip: strings.appSettings,
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: widget.onOpenSettingsDrawer,
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

  Widget _buildAttachmentPreview() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (var i = 0; i < _pendingAttachments.length; i++)
            _AttachmentChip(
              attachment: _pendingAttachments[i],
              onRemove: () {
                setState(() => _pendingAttachments.removeAt(i));
              },
            ),
        ],
      ),
    );
  }

  Future<void> _pickImage(_AiStrings strings) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        withData: true,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      final storage = context.read<StorageService>();
      final settings = await storage.loadAiConnectionSettings();
      final maxBytes = settings.maxImageSizeBytes;
      for (final file in result.files) {
        if (file.bytes == null || file.size == 0) continue;
        if (file.size > maxBytes) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(strings.imageTooLarge(
                  file.name,
                  AiUploadSizeLimit.label(maxBytes),
                )),
              ),
            );
          }
          continue;
        }
        final mimeType = _guessMimeType(file.name, fallback: 'image/png');
        setState(() {
          _pendingAttachments.add(AiChatAttachment(
            fileName: file.name,
            mimeType: mimeType,
            sizeBytes: file.size,
            dataBase64: base64Encode(file.bytes!),
          ));
        });
      }
    } catch (e) {
      AppLogService.instance.warning(
        'Image pick failed',
        details: '$e',
      );
    }
  }

  Future<void> _pickFile(_AiStrings strings) async {
    try {
      final result = await FilePicker.pickFiles(
        withData: true,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      final storage = context.read<StorageService>();
      final settings = await storage.loadAiConnectionSettings();
      final maxBytes = settings.maxFileSizeBytes;
      for (final file in result.files) {
        if (file.bytes == null || file.size == 0) continue;
        if (file.size > maxBytes) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(strings.fileTooLarge(
                  file.name,
                  AiUploadSizeLimit.label(maxBytes),
                )),
              ),
            );
          }
          continue;
        }
        final mimeType = _guessMimeType(file.name);
        setState(() {
          _pendingAttachments.add(AiChatAttachment(
            fileName: file.name,
            mimeType: mimeType,
            sizeBytes: file.size,
            dataBase64: base64Encode(file.bytes!),
          ));
        });
      }
    } catch (e) {
      AppLogService.instance.warning(
        'File pick failed',
        details: '$e',
      );
    }
  }

  static String _guessMimeType(String fileName,
      {String fallback = 'application/octet-stream'}) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.xml')) return 'text/xml';
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    if (lower.endsWith('.css')) return 'text/css';
    if (lower.endsWith('.js')) return 'text/javascript';
    if (lower.endsWith('.dart')) return 'text/plain';
    if (lower.endsWith('.py')) return 'text/plain';
    if (lower.endsWith('.md')) return 'text/markdown';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return 'text/yaml';
    if (lower.endsWith('.log')) return 'text/plain';
    if (lower.endsWith('.sh') ||
        lower.endsWith('.bat') ||
        lower.endsWith('.ps1')) {
      return 'text/plain';
    }
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.zip')) return 'application/zip';
    return fallback;
  }

  Future<void> _send(BuildContext context, _AiStrings strings) async {
    final text = (_inputController.text.trim());
    await _sendText(context, strings, text: text, clearInput: true);
  }

  bool get _shouldShowSlashCommandPanel {
    return _inputController.text.trimLeft().startsWith('/');
  }

  List<_SlashCommandMeta> get _filteredSlashCommands {
    final text = _inputController.text.trimLeft().toLowerCase();
    if (!text.startsWith('/')) {
      return const [];
    }
    final parts = text.substring(1).trimLeft().split(RegExp(r'\s+'));
    final commandHint = parts.isNotEmpty ? parts.first : '';
    if (commandHint.isEmpty) {
      return _defaultSlashCommands;
    }
    return _defaultSlashCommands
        .where((command) =>
            command.command.substring(1).toLowerCase().startsWith(commandHint))
        .toList();
  }

  Widget _buildSlashCommandPanel(BuildContext context, _AiStrings strings) {
    final suggestions = _filteredSlashCommands;
    if (suggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.36),
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              strings.commandUnknownHint,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 178),
      child: SingleChildScrollView(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: Text(
                  strings.commands,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              for (final command in suggestions)
                ListTile(
                  dense: true,
                  title: Text(command.command),
                  subtitle: Text(
                    command.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    _inputController.text = command.command == '/tools'
                        ? '/tools '
                        : command.command;
                    setState(() => _inputController.selection =
                        TextSelection.collapsed(
                            offset: _inputController.text.length));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _executeSlashCommand({
    required String chatId,
    required String input,
    required _AiStrings strings,
  }) async {
    if (!mounted) {
      return false;
    }
    final parsed = _parseSlashCommand(input);
    if (parsed == null || parsed.command.isEmpty) {
      _showCommandFeedback(strings.commandUnknown, context);
      return false;
    }
    switch (parsed.command) {
      case 'compact':
        _pendingForceCompressionChats.add(chatId);
        AppLogService.instance.info(
          'Slash command executed',
          details:
              'chatId=$chatId command=compact forceContextCompression=true',
        );
        _showCommandFeedback(strings.commandCompact, context);
        return true;
      case 'tools':
        final handled = await _executeToolsCommand(
          chatId: chatId,
          arguments: parsed.arguments,
          strings: strings,
        );
        if (handled) {
          AppLogService.instance.info(
            'Slash command executed',
            details: 'chatId=$chatId command=tools',
          );
        }
        return handled;
      case 'skills':
        final handled = await _executeSkillsCommand(
          strings: strings,
        );
        if (handled) {
          AppLogService.instance.info(
            'Slash command executed',
            details: 'chatId=$chatId command=skills',
          );
        }
        return handled;
      default:
        _showCommandFeedback(
            strings.commandUnknownWithName(parsed.command), context);
        return false;
    }
  }

  Future<bool> _executeSkillsCommand({
    required _AiStrings strings,
  }) async {
    if (!mounted) {
      return false;
    }
    await Navigator.of(context).pushNamed('/ai-skills');
    if (!mounted) {
      return false;
    }
    _showCommandFeedback(strings.commandSkillsOpened, context);
    return true;
  }

  Future<bool> _executeToolsCommand({
    required String chatId,
    required String arguments,
    required _AiStrings strings,
  }) async {
    final commandChatId = chatId;
    if (!mounted) {
      return false;
    }
    if (arguments.isEmpty) {
      final availableTools = await _loadAvailableTools(strings);
      if (!mounted || !context.mounted || _activeChat?.id != commandChatId) {
        return false;
      }
      if (availableTools == null) return false;
      final next = await _openToolsSelector(
        context: context,
        strings: strings,
        availableTools: availableTools,
        initialTools: _chatAllowedTools[chatId] ?? const {},
      );
      if (!mounted || !context.mounted || _activeChat?.id != commandChatId) {
        return false;
      }
      if (next == null) return false;
      _chatAllowedTools[chatId] = {...next};
      _showCommandFeedback(strings.commandToolsUpdated(next.length), context);
      AppLogService.instance.info(
        'Slash /tools applied',
        details: 'chatId=$chatId source=picker count=${next.length}',
      );
      return true;
    }

    final requested = _parseToolList(arguments);
    if (!mounted || _activeChat?.id != commandChatId) {
      return false;
    }
    final availableTools = await _loadAvailableTools(strings);
    if (!mounted || !context.mounted || _activeChat?.id != commandChatId) {
      return false;
    }
    if (availableTools == null) return false;
    final availableMap = <String, String>{};
    for (final tool in availableTools) {
      availableMap[tool.name.toLowerCase()] = tool.name;
    }
    final unknown = <String>[];
    final selected = <String>{};
    for (final raw in requested) {
      final normalized = raw.toLowerCase();
      final canonical = availableMap[normalized];
      if (canonical == null) {
        unknown.add(raw);
      } else {
        selected.add(canonical);
      }
    }
    if (selected.isEmpty && unknown.isNotEmpty) {
      _showCommandFeedback(
        strings.commandToolsUnknown(unknown),
        context,
      );
      return true;
    }
    if (selected.isNotEmpty) {
      _chatAllowedTools[chatId] = selected;
      _showCommandFeedback(
          strings.commandToolsUpdated(selected.length), context);
    }
    if (unknown.isNotEmpty) {
      _showCommandFeedback(
        strings.commandToolsUnknown(unknown),
        context,
      );
    }
    AppLogService.instance.info(
      'Slash /tools applied',
      details:
          'chatId=$chatId source=inline requested=${requested.join(',')} accepted=${selected.join(',')} unknown=${unknown.join(',')}',
    );
    return selected.isNotEmpty || unknown.isNotEmpty;
  }

  Future<List<_ToolOption>?> _loadAvailableTools(_AiStrings strings) async {
    if (!mounted || !context.mounted) {
      return null;
    }
    try {
      final storage = context.read<StorageService>();
      final toolService = AiToolService(
        storageService: storage,
        sshService: context.read<SshService>(),
        sftpService: context.read<SftpService>(),
        performanceMonitorToolService: PerformanceMonitorToolService(
          context.read<PerformanceMonitorService>(),
        ),
        appSettings: context.read<AppSettings>(),
        playbookService: context.read<PlaybookService>(),
      );
      final definitions = await toolService.toolDefinitions();
      final tools = <_ToolOption>[];
      for (final definition in definitions) {
        final name = _toolNameFromDefinition(definition);
        if (name == null) continue;
        final function = definition['function'];
        final description =
            function is Map<String, dynamic> ? function['description'] : null;
        tools.add(
          _ToolOption(
            name: name,
            description: description is String ? description : '',
          ),
        );
      }
      tools.sort((a, b) => a.name.compareTo(b.name));
      return tools;
    } catch (error, stackTrace) {
      if (!mounted || !context.mounted) {
        return null;
      }
      AppLogService.instance.error(
        'Failed to load tools for slash command',
        error: error,
        stackTrace: stackTrace,
      );
      _showCommandFeedback(strings.commandToolsLoadFailed, context);
      return null;
    }
  }

  Future<Set<String>?> _openToolsSelector({
    required BuildContext context,
    required _AiStrings strings,
    required List<_ToolOption> availableTools,
    required Set<String> initialTools,
  }) async {
    if (availableTools.isEmpty) {
      _showCommandFeedback(strings.commandToolsNoTools, context);
      return null;
    }
    if (!context.mounted) {
      return null;
    }
    final selected = {...initialTools};
    final searchTextController = TextEditingController();
    Set<String>? selectedSet;
    try {
      if (!context.mounted) {
        return null;
      }
      selectedSet = await showModalBottomSheet<Set<String>?>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) {
          return StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              final query = searchTextController.text.trim().toLowerCase();
              final filteredTools = availableTools
                  .where(
                    (tool) =>
                        tool.name.toLowerCase().contains(query) ||
                        tool.description.toLowerCase().contains(query),
                  )
                  .toList();
              return SafeArea(
                child: SizedBox(
                  height: MediaQuery.sizeOf(sheetContext).height *
                      (_maxToolSelectorHeightPercent / 100),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Column(
                      children: [
                        TextField(
                          controller: searchTextController,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: strings.commandToolsSearch,
                          ),
                          onChanged: (_) {
                            if (!sheetContext.mounted) {
                              return;
                            }
                            setSheetState(() {});
                          },
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: filteredTools.isEmpty
                              ? Center(
                                  child: Text(
                                    strings.commandToolsNoResult,
                                    style: TextStyle(
                                      color: Theme.of(sheetContext)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: filteredTools.length,
                                  itemBuilder: (ctx, index) {
                                    final tool = filteredTools[index];
                                    final isSelected =
                                        selected.contains(tool.name);
                                    return CheckboxListTile(
                                      value: isSelected,
                                      title: Text(tool.name),
                                      subtitle: Text(tool.description),
                                      onChanged: (value) => setSheetState(
                                        () {
                                          if (!sheetContext.mounted) {
                                            return;
                                          }
                                          if (value == true) {
                                            selected.add(tool.name);
                                          } else {
                                            selected.remove(tool.name);
                                          }
                                        },
                                      ),
                                    );
                                  },
                                ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () {
                                if (!sheetContext.mounted) return;
                                Navigator.of(sheetContext).pop();
                              },
                              child: Text(strings.cancel),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () {
                                if (!sheetContext.mounted) return;
                                Navigator.of(sheetContext)
                                    .pop(Set.from(selected));
                              },
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
          );
        },
      );
    } finally {
      searchTextController.dispose();
    }
    return selectedSet;
  }

  _ParsedSlashCommand? _parseSlashCommand(String input) {
    final trimmed = input.trim();
    if (!trimmed.startsWith('/')) return null;
    if (trimmed == '/') return const _ParsedSlashCommand('', '');
    final body = trimmed.substring(1).trimLeft();
    if (body.isEmpty) return const _ParsedSlashCommand('', '');
    final split = body.split(RegExp(r'\s+'));
    if (split.isEmpty || split.first.isEmpty) return null;
    final command = split.first.toLowerCase();
    final arguments =
        split.length == 1 ? '' : body.substring(split.first.length).trim();
    return _ParsedSlashCommand(command, arguments);
  }

  List<String> _parseToolList(String text) {
    return text
        .split(RegExp(r'[,\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  bool _consumeContextCompression(String chatId) {
    return _pendingForceCompressionChats.remove(chatId);
  }

  String? _toolNameFromDefinition(Map<String, dynamic> definition) {
    final function = definition['function'];
    if (function is! Map) return null;
    final name = function['name'];
    return name is String ? name : null;
  }

  void _showCommandFeedback(String message, BuildContext context) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  static const int _maxToolSelectorHeightPercent = 78;

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

  Future<void> _sendText(
    BuildContext context,
    _AiStrings strings, {
    required String text,
    required bool clearInput,
  }) async {
    final activeChat = _activeChat;
    if (text.isEmpty || _sending || activeChat == null) return;
    final normalizedText = text.trim();
    if (normalizedText.startsWith('/')) {
      final handled = await _executeSlashCommand(
        chatId: activeChat.id,
        input: normalizedText,
        strings: strings,
      );
      if (!mounted) {
        return;
      }
      if (handled && clearInput) {
        setState(() {
          _inputController.clear();
          _toolsExpanded = false;
        });
      }
      return;
    }

    final storage = context.read<StorageService>();
    final appSettings = context.read<AppSettings>();
    final ragService = context.read<RagService>();

    final settings = await storage.loadAiConnectionSettings();
    final currentModel = settings.model.trim();
    if (!settings.hasApiKey) {
      AppLogService.instance.warning(
        'LLM chat blocked: API key missing or invalid',
        details: 'model=$currentModel',
      );
      if (!context.mounted) return;
      await _showSettings(context, strings);
      return;
    }

    final chatId = activeChat.id;
    final now = DateTime.now();

    // RAG 知识库检索
    List<RagChunk> ragChunks = const [];
    if (appSettings.ragEnabled) {
      try {
        ragChunks = await ragService.retrieve(normalizedText);
      } catch (e) {
        AppLogService.instance.warning('RAG retrieval failed in sendText: $e');
      }
    }

    final userContextText = await _contextTextForUser(text, ragChunks: ragChunks);
    final attachments = List<AiChatAttachment>.from(_pendingAttachments);
    final userMessage = AiChatMessageRecord(
      role: 'user',
      text: text,
      contextText: userContextText,
      attachments: attachments,
      createdAt: now,
    );

    // 构建 RAG 的 UI 引用痕迹 (Citation Traces)
    final assistantTraces = <AiMessageTrace>[];
    if (ragChunks.isNotEmpty) {
      final traceContent = StringBuffer();
      final isEn = appSettings.isEnglish;
      for (final chunk in ragChunks) {
        traceContent.writeln(isEn
            ? 'Source: [${chunk.documentName}] (Chunk #${chunk.metadata['chunkIndex'] ?? 0})'
            : '来源: [${chunk.documentName}] (分块 #${chunk.metadata['chunkIndex'] ?? 0})');
        traceContent.writeln('---');
        traceContent.writeln(chunk.text);
        traceContent.writeln('========================================\n');
      }
      assistantTraces.add(AiMessageTrace(
        id: 'rag-${now.microsecondsSinceEpoch}',
        kind: 'rag_context',
        title: isEn ? 'Knowledge Base Retrieval (RAG)' : '知识库检索 (RAG)',
        content: traceContent.toString(),
        createdAt: now,
      ));
    }

    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      traces: assistantTraces,
      createdAt: now,
    );
    final nextMessages = [
      ...activeChat.messages,
      userMessage,
      assistantMessage,
    ];
    final nextChat = activeChat.copyWith(
      title: activeChat.messages.isEmpty ? _titleFrom(text, strings) : null,
      model: currentModel.isNotEmpty ? currentModel : activeChat.model,
      messages: nextMessages,
      updatedAt: now,
    );

    setState(() {
      _replaceChat(nextChat);
      _sending = true;
      if (_scrollController.hasClients) {
        _isUserAtBottom = _isNearBottom(_scrollController.position);
      } else {
        _isUserAtBottom = true;
      }
      if (clearInput) _inputController.clear();
      _pendingAttachments.clear();
      _toolsExpanded = false;
    });
    await storage.saveAiChat(nextChat);
    _scrollToBottom();

    await _generateAssistantResponse(
      chatId: chatId,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: currentModel.isNotEmpty ? currentModel : nextChat.model,
      requestMessages: nextMessages,
      strings: strings,
    );
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

  Future<void> _generateAssistantResponse({
    required String chatId,
    required AiChatRecord initialChat,
    required AiChatMessageRecord assistantMessage,
    required String model,
    required List<AiChatMessageRecord> requestMessages,
    required _AiStrings strings,
  }) async {
    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    final sftp = context.read<SftpService>();
    final service = LlmChatService(
      storageService: storage,
      toolService: AiToolService(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
        performanceMonitorToolService: PerformanceMonitorToolService(
          context.read<PerformanceMonitorService>(),
        ),
        appSettings: context.read<AppSettings>(),
        playbookService: context.read<PlaybookService>(),
        clientWebViewSessionId: chatId,
      ),
    );
    final cancellationToken = LlmCancellationToken();
    _activeCancellationToken = cancellationToken;
    final answer = StringBuffer();
    final forceContextCompression = _consumeContextCompression(chatId);
    final allowedTools = _chatAllowedTools[chatId];
    if (mounted) {
      setState(() {
        _beginStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
          status: strings.assistantPreparing,
        );
      });
    }

    try {
      LlmRunStats? runStats;
      var lastStreamUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final chunk in service.stream(
        modelOverride: model,
        onStats: (stats) => runStats = stats,
        onTrace: (event) {
          _updateStreamingAssistantStatus(
            _assistantStatusForTrace(event, strings),
          );
          _appendTraceToAssistant(
            chatId: chatId,
            assistantCreatedAt: assistantMessage.createdAt,
            event: event,
          );
        },
        requestToolApproval: (request) {
          return _requestToolApproval(
            chatId: chatId,
            request: request,
          );
        },
        allowedTools: allowedTools,
        forceContextCompression: forceContextCompression,
        cancellationToken: cancellationToken,
        messages: _messagesForRequest(
          requestMessages,
          placeholder: assistantMessage,
        ),
      )) {
        answer.write(chunk);
        _updateStreamingAssistantStatus(strings.assistantResponding);
        if (!mounted) return;
        final now = DateTime.now();
        if (now.difference(lastStreamUiUpdate) <
            const Duration(milliseconds: 120)) {
          continue;
        }
        lastStreamUiUpdate = now;
        _updateStreamingAssistant(answer.toString());
        _scrollToBottom();
      }
      if (!mounted) return;
      final currentChat = _chatById(chatId) ?? initialChat;
      final completedMessages = [...currentChat.messages];
      final assistantIndex = completedMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        completedMessages[assistantIndex] =
            completedMessages[assistantIndex].copyWith(
          text: answer.toString(),
          contextText: _contextTextForAssistant(
            answer.toString(),
            traces: completedMessages[assistantIndex].traces,
          ),
          promptTokens: runStats?.promptTokens,
          completionTokens: runStats?.completionTokens,
          totalTokens: runStats?.totalTokens,
          elapsedMs: runStats?.elapsedMs,
          tokenUsageEstimated:
              runStats == null ? null : !runStats!.usageFromProvider,
          promptCacheHitTokens: runStats?.promptCacheHitTokens,
          promptCacheMissTokens: runStats?.promptCacheMissTokens,
          reasoningTokens: runStats?.reasoningTokens,
        );
      }
      final answeredChat = currentChat.copyWith(
        messages: completedMessages,
        updatedAt: DateTime.now(),
      );
      setState(() {
        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(answeredChat);
      });
      await storage.saveAiChat(answeredChat);
    } on LlmCancelledException {
      AppLogService.instance.info(
        'LLM chat UI request cancelled',
        details: 'chatId=$chatId model=$model',
      );
      if (!mounted) return;
      final currentChat = _chatById(chatId) ?? initialChat;
      final cancelledMessages = [...currentChat.messages];
      final assistantIndex = cancelledMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        final stoppedText = answer.toString().trim().isEmpty
            ? strings.stopped
            : '${answer.toString()}\n\n${strings.stopped}';
        final traces = [
          ...cancelledMessages[assistantIndex].traces,
          AiMessageTrace.create(
            kind: 'approval',
            title: 'Stopped by user',
            content: strings.stopped,
          ),
        ];
        cancelledMessages[assistantIndex] =
            cancelledMessages[assistantIndex].copyWith(
          text: stoppedText,
          traces: traces,
          contextText: _contextTextForAssistant(stoppedText, traces: traces),
        );
      }
      final cancelledChat = currentChat.copyWith(
        messages: cancelledMessages,
        updatedAt: DateTime.now(),
      );
      setState(() {
        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(cancelledChat);
      });
      await storage.saveAiChat(cancelledChat);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM chat UI request failed',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=$chatId model=$model',
      );
      if (!mounted) return;
      final currentChat = _chatById(chatId) ?? initialChat;
      final errorMessages = [...currentChat.messages];
      final assistantIndex = errorMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        final partialText = answer.toString();
        if (partialText.trim().isEmpty &&
            errorMessages[assistantIndex].text.isEmpty) {
          errorMessages.removeAt(assistantIndex);
        } else if (partialText.isNotEmpty) {
          errorMessages[assistantIndex] =
              errorMessages[assistantIndex].copyWith(
            text: partialText,
            contextText: _contextTextForAssistant(
              partialText,
              traces: errorMessages[assistantIndex].traces,
            ),
          );
        }
      }
      final errorChat = currentChat.copyWith(
        messages: [
          ...errorMessages,
          AiChatMessageRecord(
            role: 'error',
            text: strings.failed(e),
            createdAt: DateTime.now(),
          ),
        ],
        updatedAt: DateTime.now(),
      );
      setState(() {
        _clearStreamingAssistant(
          chatId: chatId,
          assistantCreatedAt: assistantMessage.createdAt,
        );
        _replaceChat(errorChat);
      });
      await storage.saveAiChat(errorChat);
    } finally {
      if (mounted) {
        setState(() {
          _clearStreamingAssistant(
            chatId: chatId,
            assistantCreatedAt: assistantMessage.createdAt,
          );
          _sending = false;
          if (_pendingApproval?.chatId == chatId) {
            _pendingApproval = null;
          }
          if (identical(_activeCancellationToken, cancellationToken)) {
            _activeCancellationToken = null;
          }
        });
        _scrollToBottom();
      }
    }
  }

  Future<AiToolApprovalDecision> _requestToolApproval({
    required String chatId,
    required AiToolApprovalRequest request,
  }) {
    final completer = Completer<AiToolApprovalDecision>();
    if (!mounted) {
      return Future.value(const AiToolApprovalDecision.rejected());
    }
    _updateStreamingAssistantStatus(
      _AiStrings(context.read<AppSettings>().language)
          .assistantAwaitingApproval(request.connectionName),
    );
    setState(() {
      _pendingApproval = _PendingToolApproval(
        chatId: chatId,
        request: request,
        completer: completer,
      );
    });
    _scrollToBottom();
    return completer.future;
  }

  void _resolvePendingApproval({required bool approved}) {
    final pending = _pendingApproval;
    if (pending == null || pending.completer.isCompleted) return;
    setState(() => _pendingApproval = null);
    pending.completer.complete(
      approved
          ? const AiToolApprovalDecision.approved()
          : const AiToolApprovalDecision.rejected(),
    );
  }

  void _stopGeneration() {
    if (!_sending) return;
    _activeCancellationToken?.cancel();
    final pending = _pendingApproval;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(
        const AiToolApprovalDecision.rejected(abort: true),
      );
    }
    setState(() => _pendingApproval = null);
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
    final strings = _AiStrings(context.read<AppSettings>().language);
    final activeChat = _activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'assistant') return;

    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      if (mounted) await _showSettings(context, strings);
      return;
    }
    if (!mounted) return;

    final prefix = activeChat.messages.take(messageIndex).toList();
    if (prefix.where((message) => message.role == 'user').isEmpty) return;
    final now = DateTime.now();
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [...prefix, assistantMessage];
    final nextModel =
        settings.model.trim().isNotEmpty ? settings.model : activeChat.model;
    final nextChat = activeChat.copyWith(
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    setState(() {
      _replaceChat(nextChat);
      _sending = true;
    });
    await storage.saveAiChat(nextChat);
    _scrollToBottom();
    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      strings: strings,
    );
  }

  Future<void> _editUserMessage(int messageIndex, _AiStrings strings) async {
    final activeChat = _activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'user') return;

    final editedText = await _showEditUserDialog(target.text, strings);
    if (!mounted) return;
    if (editedText == null) return;
    final trimmedEditedText = editedText.trim();
    if (trimmedEditedText.isEmpty) return;
    if (!mounted) return;

    final latestActiveChat = _activeChat;
    if (latestActiveChat == null || latestActiveChat.id != activeChat.id) {
      return;
    }
    final targetIndex = latestActiveChat.messages.indexWhere(
      (message) =>
          message.role == 'user' && message.createdAt == target.createdAt,
    );
    if (targetIndex < 0 || targetIndex >= latestActiveChat.messages.length) {
      return;
    }

    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      if (mounted) await _showSettings(context, strings);
      return;
    }
    if (!mounted) return;

    final currentTarget = latestActiveChat.messages[targetIndex];
    if (currentTarget.role != 'user') return;

    final now = DateTime.now();
    final editedUser = currentTarget.copyWith(
      text: trimmedEditedText,
      createdAt: now,
    );
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [
      ...latestActiveChat.messages.take(targetIndex),
      editedUser,
      assistantMessage,
    ];
    final nextModel = settings.model.trim().isNotEmpty
        ? settings.model
        : latestActiveChat.model;
    final nextChat = latestActiveChat.copyWith(
      title: targetIndex == 0 ? _titleFrom(trimmedEditedText, strings) : null,
      model: nextModel,
      messages: nextMessages,
      updatedAt: now,
    );

    setState(() {
      _replaceChat(nextChat);
      _sending = true;
    });
    await storage.saveAiChat(nextChat);
    _scrollToBottom();
    await _generateAssistantResponse(
      chatId: activeChat.id,
      initialChat: nextChat,
      assistantMessage: assistantMessage,
      model: nextModel,
      requestMessages: nextMessages,
      strings: strings,
    );
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
    final activeChat = _activeChat;
    if (_sending || activeChat == null) return;
    if (messageIndex < 0 || messageIndex >= activeChat.messages.length) return;
    final target = activeChat.messages[messageIndex];
    if (target.role != 'assistant') return;

    final now = DateTime.now();
    final branch = AiChatRecord(
      id: 'ai-${now.microsecondsSinceEpoch}',
      title: '${activeChat.title} ${strings.branchSuffix}',
      model: activeChat.model,
      messages: activeChat.messages.take(messageIndex + 1).toList(),
      createdAt: now,
      updatedAt: now,
    );
    setState(() {
      _chats = [branch, ..._chats];
      if (branch.messages.isNotEmpty) {
        _savedHistoryChats = [branch, ..._savedHistoryChats];
        _historyLoadStarted = true;
      }
      _activeChatId = branch.id;
    });
    await context.read<StorageService>().saveAiChat(branch);
    _scrollToBottom();
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
                  child: Material(
                    color: colorScheme.surface,
                    elevation: 16,
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

  Future<void> _showRagBottomSheet(BuildContext context, _AiStrings strings) async {
    final appSettings = context.read<AppSettings>();
    final storage = context.read<StorageService>();
    final aliyunKey = await storage.getAliyunApiKey();
    final hasAliyunKey = aliyunKey != null && aliyunKey.isNotEmpty;

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final theme = Theme.of(context);
          final ragEnabled = appSettings.ragEnabled;
          final searchMode = appSettings.ragSearchMode;
          final topN = appSettings.ragTopN;

          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_stories, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          strings.ragTitle,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.ragTitle),
                  subtitle: Text(strings.ragHint),
                  value: ragEnabled,
                  onChanged: (value) async {
                    await appSettings.setRagEnabled(value);
                    setState(() {});
                  },
                ),
                if (ragEnabled) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: searchMode,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: strings.ragSearchMode,
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'bm25',
                        child: Text(strings.ragSearchModeBm25),
                      ),
                      DropdownMenuItem(
                        value: 'vector',
                        child: Text(strings.ragSearchModeVector),
                      ),
                      DropdownMenuItem(
                        value: 'hybrid',
                        child: Text(strings.ragSearchModeHybrid),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value != null) {
                        await appSettings.setRagSearchMode(value);
                        setState(() {});
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<int>(
                    initialValue: topN,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: strings.ragTopN,
                      isDense: true,
                    ),
                    items: [
                      for (final value in [1, 2, 3, 4, 5, 6, 8, 10])
                        DropdownMenuItem(
                          value: value,
                          child: Text(strings.ragTopNValue(value)),
                        ),
                    ],
                    onChanged: (value) async {
                      if (value != null) {
                        await appSettings.setRagTopN(value);
                        setState(() {});
                      }
                    },
                  ),
                  if ((searchMode == 'vector' || searchMode == 'hybrid') && !hasAliyunKey) ...[
                    const SizedBox(height: 10),
                    Text(
                      strings.ragSearchModeNeedKey,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  icon: const Icon(Icons.folder_shared_outlined),
                  label: Text(strings.ragManage),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(context, '/rag-knowledge');
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _appendTraceToAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required LlmTraceEvent event,
  }) {
    if (!mounted) return;
    final currentChat = _chatById(chatId);
    if (currentChat == null) return;
    final messages = [...currentChat.messages];
    final assistantIndex = messages.indexWhere(
      (message) =>
          message.role == 'assistant' &&
          message.createdAt == assistantCreatedAt,
    );
    if (assistantIndex < 0) return;
    messages[assistantIndex] = messages[assistantIndex].copyWith(
      traces: [
        ...messages[assistantIndex].traces,
        AiMessageTrace.create(
          kind: event.kind,
          title: event.title,
          content: event.content,
        ),
      ],
    );
    setState(() {
      _replaceChat(
        currentChat.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        ),
        sort: false,
      );
    });
    _scrollToBottom();
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
      ragLines.add(isEn ? '【Ops Knowledge Base Reference Information】:' : '【运维知识库参考信息】：');
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

  void _beginStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
    required String status,
  }) {
    _streamingAssistantTarget = _StreamingAssistantTarget(
      chatId: chatId,
      assistantCreatedAt: assistantCreatedAt,
    );
    _streamingAssistantText.value = '';
    _streamingAssistantStatus.value = status;
  }

  void _updateStreamingAssistant(String text) {
    if (_streamingAssistantText.value == text) return;
    _streamingAssistantText.value = text;
  }

  void _updateStreamingAssistantStatus(String status) {
    if (!mounted || _streamingAssistantTarget == null) return;
    if (_streamingAssistantStatus.value == status) return;
    _streamingAssistantStatus.value = status;
  }

  String _assistantStatusForTrace(
    LlmTraceEvent event,
    _AiStrings strings,
  ) {
    switch (event.kind) {
      case 'reasoning':
        return strings.assistantThinking;
      case 'tool_request':
        return strings.assistantRunningTool(_traceToolName(event.title));
      case 'tool_result':
        return strings.assistantProcessingToolResult;
      case 'approval':
        return strings.assistantProcessingApproval;
      case 'multi_agent':
        return strings.assistantCollaborating;
      default:
        return strings.assistantPreparing;
    }
  }

  String _traceToolName(String title) {
    final index = title.indexOf(':');
    if (index < 0 || index == title.length - 1) return title;
    return title.substring(index + 1).trim();
  }

  void _clearStreamingAssistant({
    required String chatId,
    required DateTime assistantCreatedAt,
  }) {
    final target = _streamingAssistantTarget;
    if (target == null ||
        target.chatId != chatId ||
        target.assistantCreatedAt != assistantCreatedAt) {
      return;
    }
    _streamingAssistantTarget = null;
    _streamingAssistantText.value = '';
    _streamingAssistantStatus.value = '';
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
      if (!shouldJump && _sending && !_isUserAtBottom) return;
      if (shouldJump || _sending) {
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

  @override
  bool get wantKeepAlive => true;
}

