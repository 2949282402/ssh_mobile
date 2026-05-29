import 'dart:async';

// ignore_for_file: unused_element

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
import '../services/performance_monitor_service.dart';
import '../services/performance_monitor_tool_service.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../widgets/overflow_scroll_text.dart';

part 'llm_chat/assistant_run_indicator.dart';

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

  const LlmChatScreen({
    super.key,
    this.active = true,
    this.onHistoryVisibilityChanged,
    this.onOpenSettingsDrawer,
  });

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
  String? _selectedConnectionId;
  final Map<String, Set<String>> _chatAllowedTools = {};
  final Set<String> _pendingForceCompressionChats = {};
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

  @override
  void initState() {
    super.initState();
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
                            streamingStatusListenable: streamingStatusListenable,
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
                            onContinueTimeout:
                                message.role == 'error' &&
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
                                    onServerTap: () =>
                                        _selectTargetServer(strings),
                                    onSkillsTap: () {
                                      Navigator.pushNamed(
                                          context, '/ai-skills');
                                    },
                                    onWebViewTap: () =>
                                        _openClientWebView(activeChat.id),
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
    final id = _selectedConnectionId;
    if (id == null) return strings.serverTarget;
    final connection = context.read<StorageService>().getConnection(id);
    return connection == null ? strings.serverTarget : connection.name;
  }

  Future<void> _selectTargetServer(_AiStrings strings) async {
    final storage = context.read<StorageService>();
    final selected = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.clear_rounded),
              title: Text(strings.noDefaultServer),
              onTap: () => Navigator.pop(ctx, null),
            ),
            for (final connection in storage.connections)
              ListTile(
                leading: Icon(
                  connection.id == _selectedConnectionId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(connection.name),
                subtitle: Text('${connection.username}@${connection.host}'),
                onTap: () => Navigator.pop(ctx, connection.id),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _selectedConnectionId = selected);
  }

  Future<void> _openClientWebView(String chatId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClientWebViewScreen(chatId: chatId),
      ),
    );
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
        .where((command) => command.command
            .substring(1)
            .toLowerCase()
            .startsWith(commandHint))
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
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              strings.commandUnknownHint,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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
                    _inputController.text =
                        command.command == '/tools' ? '/tools ' : command.command;
                    setState(() => _inputController.selection =
                        TextSelection.collapsed(offset: _inputController.text.length));
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
      default:
        _showCommandFeedback(strings.commandUnknownWithName(parsed.command), context);
        return false;
    }
  }

  Future<bool> _executeToolsCommand({
    required String chatId,
    required String arguments,
    required _AiStrings strings,
  }) async {
    if (!mounted) {
      return false;
    }
    if (arguments.isEmpty) {
      final availableTools = await _loadAvailableTools(strings);
      if (!mounted || !context.mounted) {
        return false;
      }
      if (availableTools == null) return false;
      final next = await _openToolsSelector(
        context: context,
        strings: strings,
        availableTools: availableTools,
        initialTools: _chatAllowedTools[chatId] ?? const {},
      );
      if (!mounted || !context.mounted) {
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
    if (!mounted) {
      return false;
    }
    final availableTools = await _loadAvailableTools(strings);
    if (!mounted || !context.mounted) {
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
      _showCommandFeedback(strings.commandToolsUpdated(selected.length), context);
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
      );
      final definitions = await toolService.toolDefinitions();
      final tools = <_ToolOption>[];
      for (final definition in definitions) {
        if (definition is! Map<String, dynamic>) continue;
        final name = _toolNameFromDefinition(definition);
        if (name == null) continue;
        final function = definition['function'];
        final description = function is Map<String, dynamic>
            ? function['description']
            : null;
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
                  height:
                      MediaQuery.sizeOf(sheetContext).height *
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
                          onChanged: (_) => setSheetState(() {}),
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
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: Text(strings.cancel),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(sheetContext).pop(Set.from(selected)),
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
    final arguments = split.length == 1 ? '' : body.substring(split.first.length).trim();
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
        setState(() => _inputController.clear());
      }
      return;
    }

    final storage = context.read<StorageService>();
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
    final userContextText = await _contextTextForUser(text);
    final userMessage = AiChatMessageRecord(
      role: 'user',
      text: text,
      contextText: userContextText,
      createdAt: now,
    );
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
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
    if (latestActiveChat == null || latestActiveChat.id != activeChat.id) return;
    final targetIndex = latestActiveChat.messages.indexWhere(
      (message) =>
          message.role == 'user' &&
          message.createdAt == target.createdAt,
    );
    if (targetIndex < 0 || targetIndex >= latestActiveChat.messages.length) return;

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
    final nextModel =
        settings.model.trim().isNotEmpty ? settings.model : latestActiveChat.model;
    final nextChat = latestActiveChat.copyWith(
      title:
          targetIndex == 0 ? _titleFrom(trimmedEditedText, strings) : null,
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
    final controller = TextEditingController(text: text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.editMessage),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(strings.saveAndSend),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
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

    final baseUrlController = TextEditingController(text: settings.baseUrl);
    final modelController = TextEditingController(text: settings.model);
    final apiKeyController = TextEditingController();
    var models = _modelOptions(settings.model);
    var contextWindowTokens = settings.contextWindowTokens;
    var timeoutSeconds = settings.timeoutSeconds;
    var deepSeekThinkingEnabled = settings.deepSeekThinkingEnabled;
    var deepSeekReasoningEffort = settings.deepSeekReasoningEffort;
    var webSearchEnabled = settings.webSearchEnabled;
    var webSearchMaxResults = settings.webSearchMaxResults;
    var loadingModels = false;
    var savingSettings = false;
    String? modelLoadError;

    Future<void> refreshModels(
      BuildContext ctx,
      void Function(void Function()) setDialogState,
    ) async {
      final typedApiKey = apiKeyController.text.trim();
      setDialogState(() {
        loadingModels = true;
        modelLoadError = null;
      });
      try {
        final service = LlmChatService(
          storageService: storage,
          toolService: AiToolService(
            storageService: storage,
            sshService: context.read<SshService>(),
            sftpService: context.read<SftpService>(),
            performanceMonitorToolService: PerformanceMonitorToolService(
              context.read<PerformanceMonitorService>(),
            ),
            appSettings: context.read<AppSettings>(),
          ),
        );
        final fetched = await service.fetchModels(
          baseUrl: baseUrlController.text.trim(),
          apiKey: typedApiKey.isEmpty ? null : typedApiKey,
        );
        if (!ctx.mounted) return;
        setDialogState(() {
          models = resolveFetchedModelOptions(
            fetchedModels: fetched,
            fallbackModels: models,
          );
          loadingModels = false;
          if (models.isNotEmpty && !models.contains(modelController.text)) {
            modelController.text = models.first;
          }
        });
      } catch (e, stackTrace) {
        AppLogService.instance.error(
          'LLM model refresh failed in settings',
          error: e,
          stackTrace: stackTrace,
          details: 'baseUrl=${baseUrlController.text.trim()}',
        );
        if (!ctx.mounted) return;
        setDialogState(() {
          loadingModels = false;
          modelLoadError = e.toString();
        });
      }
    }

    final nextSettings = await showDialog<_PendingAiSettings>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(strings.settings),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: baseUrlController,
                    decoration: InputDecoration(labelText: strings.baseUrl),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: models.contains(modelController.text)
                              ? modelController.text
                              : models.first,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: strings.model),
                          selectedItemBuilder: (context) => [
                            for (final model in models)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  model,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false,
                                ),
                              ),
                          ],
                          items: [
                            for (final model in models)
                              DropdownMenuItem(
                                value: model,
                                child: Text(
                                  model,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) modelController.text = value;
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: strings.refreshModels,
                        icon: loadingModels
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync_rounded),
                        onPressed: loadingModels
                            ? null
                            : () => refreshModels(ctx, setDialogState),
                      ),
                    ],
                  ),
                  if (modelLoadError != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        strings.modelsFailed(modelLoadError!),
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: contextWindowTokens,
                    isExpanded: true,
                    decoration:
                        const InputDecoration(labelText: 'Context window'),
                    items: [
                      for (final value in AiContextWindowSize.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(AiContextWindowSize.label(value)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) contextWindowTokens = value;
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: timeoutSeconds,
                    isExpanded: true,
                    decoration:
                        InputDecoration(labelText: strings.requestTimeout),
                    items: [
                      for (final value in AiRequestTimeout.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(AiRequestTimeout.label(value)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) timeoutSeconds = value;
                    },
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.deepSeekThinking),
                    subtitle: Text(strings.deepSeekThinkingHint),
                    value: deepSeekThinkingEnabled,
                    onChanged: savingSettings
                        ? null
                        : (value) {
                            setDialogState(
                              () => deepSeekThinkingEnabled = value,
                            );
                          },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: DeepSeekReasoningEffort.normalize(
                      deepSeekReasoningEffort,
                    ),
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: strings.deepSeekReasoningEffort,
                    ),
                    items: [
                      for (final value in DeepSeekReasoningEffort.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(DeepSeekReasoningEffort.label(value)),
                        ),
                    ],
                    onChanged: savingSettings || !deepSeekThinkingEnabled
                        ? null
                        : (value) {
                            if (value != null) {
                              deepSeekReasoningEffort = value;
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.webSearch),
                    subtitle: Text(strings.webSearchHint),
                    value: webSearchEnabled,
                    onChanged: savingSettings
                        ? null
                        : (value) {
                            setDialogState(() => webSearchEnabled = value);
                          },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue:
                        AiWebSearchMaxResults.normalize(webSearchMaxResults),
                    isExpanded: true,
                    decoration:
                        InputDecoration(labelText: strings.webSearchMaxResults),
                    items: [
                      for (final value in AiWebSearchMaxResults.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text('$value'),
                        ),
                    ],
                    onChanged: savingSettings || !webSearchEnabled
                        ? null
                        : (value) {
                            if (value != null) webSearchMaxResults = value;
                          },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: apiKeyController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: settings.hasApiKey
                          ? strings.apiKeySaved
                          : strings.apiKeyRequired,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: savingSettings ? null : () => Navigator.pop(ctx),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: savingSettings
                  ? null
                  : () async {
                      FocusScope.of(ctx).unfocus();
                      final pending = _PendingAiSettings(
                        baseUrl: baseUrlController.text,
                        model: modelController.text,
                        contextWindowTokens: contextWindowTokens,
                        timeoutSeconds: timeoutSeconds,
                        deepSeekThinkingEnabled: deepSeekThinkingEnabled,
                        deepSeekReasoningEffort: deepSeekReasoningEffort,
                        openAiReasoningEffort: settings.openAiReasoningEffort,
                        webSearchEnabled: webSearchEnabled,
                        webSearchMaxResults: webSearchMaxResults,
                        apiKey: apiKeyController.text,
                        selectedApiKeyId: settings.activeApiKeyId,
                      );
                      setDialogState(() {
                        savingSettings = true;
                        modelLoadError = null;
                      });
                      try {
                        await storage.saveAiConnectionSettings(
                          baseUrl: pending.baseUrl,
                          model: pending.model,
                          contextWindowTokens: pending.contextWindowTokens,
                          timeoutSeconds: pending.timeoutSeconds,
                          deepSeekThinkingEnabled:
                              pending.deepSeekThinkingEnabled,
                          deepSeekReasoningEffort:
                              pending.deepSeekReasoningEffort,
                          openAiReasoningEffort: pending.openAiReasoningEffort,
                          webSearchEnabled: pending.webSearchEnabled,
                          webSearchMaxResults: pending.webSearchMaxResults,
                          apiKey: pending.apiKey,
                          selectedApiKeyId: pending.selectedApiKeyId,
                        );
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx, pending);
                      } catch (e, stackTrace) {
                        AppLogService.instance.error(
                          'LLM settings save failed',
                          error: e,
                          stackTrace: stackTrace,
                          details:
                              'baseUrl=${pending.baseUrl.trim()} model=${pending.model.trim()} apiKeyProvided=${pending.apiKey.trim().isNotEmpty}',
                        );
                        if (!ctx.mounted) return;
                        setDialogState(() {
                          savingSettings = false;
                          modelLoadError = e.toString();
                        });
                      }
                    },
              child: savingSettings
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(strings.save),
            ),
          ],
        ),
      ),
    );

    baseUrlController.dispose();
    modelController.dispose();
    apiKeyController.dispose();

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
          final content = _contextContentFor(message);
          if (content.trim().isEmpty) return null;
          return <String, dynamic>{
            'role': message.role == 'user' ? 'user' : 'assistant',
            'content': content,
          };
        })
        .nonNulls
        .toList();
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

  Future<String?> _contextTextForUser(String text) async {
    final lines = <String>[];
    final connectionId = _selectedConnectionId;
    if (connectionId != null) {
      final connection =
          context.read<StorageService>().getConnection(connectionId);
      if (connection != null) {
        lines.add(
          'Default target server: ${connection.name} (id: ${connection.id}, host: ${connection.username}@${connection.host}:${connection.port})',
        );
      }
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

class _StreamingAssistantTarget {
  final String chatId;
  final DateTime assistantCreatedAt;

  const _StreamingAssistantTarget({
    required this.chatId,
    required this.assistantCreatedAt,
  });
}

class _MessageBubble extends StatelessWidget {
  final AiChatMessageRecord message;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;
  final bool canAct;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;
  final VoidCallback? onContinueTimeout;

  const _MessageBubble({
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
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              decoration: BoxDecoration(
                color: isError
                    ? colorScheme.error.withValues(alpha: 0.1)
                    : isUser
                        ? colorScheme.primary.withValues(alpha: 0.12)
                        : colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isError
                      ? colorScheme.error.withValues(alpha: 0.38)
                      : isUser
                          ? colorScheme.primary.withValues(alpha: 0.10)
                          : colorScheme.outlineVariant.withValues(alpha: 0.78),
                ),
              ),
              child: isUser || isError
                  ? SelectableText(
                      message.text.isEmpty ? '...' : message.text,
                      style: TextStyle(
                        color:
                            isError ? colorScheme.error : colorScheme.onSurface,
                        height: 1.35,
                      ),
                    )
                  : _AssistantMarkdownBody(
                      text: message.text,
                      streamingTextListenable: streamingTextListenable,
                      streamingStatusListenable: streamingStatusListenable,
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

class _AssistantMarkdownBody extends StatelessWidget {
  final String text;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;

  const _AssistantMarkdownBody({
    required this.text,
    this.streamingTextListenable,
    this.streamingStatusListenable,
  });

  @override
  Widget build(BuildContext context) {
    final listenable = streamingTextListenable;
    if (listenable == null) {
      return _buildMarkdown(context, text);
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
                  child: _buildMarkdown(context, displayText),
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

class _HistoryPanel extends StatefulWidget {
  final List<AiChatRecord> chats;
  final String? activeChatId;
  final bool loading;
  final _AiStrings strings;
  final String Function(DateTime time) formatTime;
  final VoidCallback onClose;
  final VoidCallback onNewChat;
  final ValueChanged<String> onSelectChat;
  final Future<void> Function(String chatId) onDeleteChat;

  const _HistoryPanel({
    required this.chats,
    required this.activeChatId,
    required this.loading,
    required this.strings,
    required this.formatTime,
    required this.onClose,
    required this.onNewChat,
    required this.onSelectChat,
    required this.onDeleteChat,
  });

  @override
  State<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<_HistoryPanel> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<AiChatRecord> get _filteredChats {
    if (_searchQuery.isEmpty) return widget.chats;
    final query = _searchQuery.toLowerCase();
    return widget.chats.where((chat) {
      if (chat.title.toLowerCase().contains(query)) {
        return true;
      }
      return chat.messages.any((message) {
        final text = message.text.toLowerCase();
        if (text.contains(query)) return true;
        final contextText = message.contextText;
        return contextText != null && contextText.toLowerCase().contains(query);
      });
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final filtered = _filteredChats;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: widget.strings.close,
                icon: const Icon(Icons.close_rounded),
                onPressed: widget.onClose,
              ),
              Expanded(
                child: Text(
                  widget.strings.history,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: widget.strings.newChat,
                icon: const Icon(Icons.add_rounded),
                onPressed: widget.onNewChat,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value),
            decoration: InputDecoration(
              hintText: widget.strings.language == AppLanguage.en
                  ? 'Search history'
                  : '搜索历史记录',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        Expanded(
          child: widget.loading
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : filtered.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isNotEmpty
                            ? (widget.strings.language == AppLanguage.en
                                ? 'No results'
                                : '无搜索结果')
                            : (widget.strings.language == AppLanguage.en
                                ? 'No history'
                                : '暂无历史记录'),
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final chat = filtered[index];
                        final selected = chat.id == widget.activeChatId;
                        return ListTile(
                          selected: selected,
                          leading: Icon(
                            selected
                                ? Icons.chat_bubble_rounded
                                : Icons.chat_bubble_outline_rounded,
                            color: selected ? colorScheme.primary : null,
                          ),
                          title: Text(
                            chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            widget.formatTime(chat.updatedAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: widget.strings.delete,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => widget.onDeleteChat(chat.id),
                          ),
                          onTap: () => widget.onSelectChat(chat.id),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _ChatToolsBar extends StatelessWidget {
  final String skillsLabel;
  final String serverLabel;
  final String webViewLabel;
  final VoidCallback onServerTap;
  final VoidCallback onSkillsTap;
  final VoidCallback onWebViewTap;

  const _ChatToolsBar({
    required this.skillsLabel,
    required this.serverLabel,
    required this.webViewLabel,
    required this.onServerTap,
    required this.onSkillsTap,
    required this.onWebViewTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 100, maxHeight: 164),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final spacing = 10.0;
            final tileWidth = (constraints.maxWidth - spacing) / 2;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.dns_outlined,
                  label: Text(serverLabel),
                  onPressed: onServerTap,
                ),
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.auto_awesome_outlined,
                  label: Text(skillsLabel),
                  onPressed: onSkillsTap,
                ),
                _ChatToolTile(
                  width: tileWidth,
                  icon: Icons.language_rounded,
                  label: Text(webViewLabel),
                  onPressed: onWebViewTap,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ChatToolTile extends StatelessWidget {
  final double width;
  final IconData icon;
  final Widget label;
  final VoidCallback onPressed;

  const _ChatToolTile({
    required this.width,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Icon(icon, size: 20, color: colorScheme.primary),
              ),
              const SizedBox(height: 4),
              DefaultTextStyle.merge(
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                ),
                child: label,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PromptTemplate {
  final String title;
  final String text;

  const _PromptTemplate({
    required this.title,
    required this.text,
  });

  static List<_PromptTemplate> defaults(_AiStrings strings) {
    final en = strings.language == AppLanguage.en;
    return [
      _PromptTemplate(
        title: en ? 'Diagnose service' : '排查服务',
        text: en
            ? 'Check the service status, recent errors, listening ports, and resource usage. Summarize findings and recommend next steps.'
            : '检查服务状态、近期错误、监听端口和资源占用，总结发现并给出下一步建议。',
      ),
      _PromptTemplate(
        title: en ? 'Analyze logs' : '分析日志',
        text: en
            ? 'Analyze the recent logs, identify likely root causes, and separate confirmed facts from guesses.'
            : '分析近期日志，找出可能根因，并区分已确认事实和推测。',
      ),
      _PromptTemplate(
        title: en ? 'Pre-deploy check' : '部署前检查',
        text: en
            ? 'Run a safe pre-deployment checklist: disk, memory, process status, git status if applicable, and risky changes to watch.'
            : '执行安全的部署前检查：磁盘、内存、进程状态、必要时检查 git 状态，并指出需要注意的风险。',
      ),
    ];
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
              // Stable trace ids keep the expanded SelectableText subtree bound
              // to the same logical tool event while streaming appends rebuild.
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
      default:
        return trace.title;
    }
  }

  IconData _traceIcon(String kind) {
    switch (kind) {
      case 'reasoning':
        return Icons.psychology_alt_outlined;
      case 'tool_request':
        return Icons.build_circle_outlined;
      case 'tool_result':
        return Icons.fact_check_outlined;
      case 'approval':
        return Icons.verified_user_outlined;
      default:
        return Icons.info_outline;
    }
  }

  Color _traceColor(ColorScheme colorScheme, String kind) {
    switch (kind) {
      case 'reasoning':
        return colorScheme.secondary;
      case 'tool_request':
        return colorScheme.primary;
      case 'tool_result':
        return colorScheme.tertiary;
      case 'approval':
        return colorScheme.error;
      default:
        return colorScheme.onSurfaceVariant;
    }
  }
}

class _PendingToolApproval {
  final String chatId;
  final AiToolApprovalRequest request;
  final Completer<AiToolApprovalDecision> completer;

  const _PendingToolApproval({
    required this.chatId,
    required this.request,
    required this.completer,
  });
}

class _ToolApprovalPanel extends StatelessWidget {
  final _PendingToolApproval pending;
  final _AiStrings strings;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _ToolApprovalPanel({
    required this.pending,
    required this.strings,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final en = strings.language == AppLanguage.en;
    final title = switch (pending.request.approvalType) {
      'remote_delete' => en ? 'Approve remote delete' : '确认远端删除操作',
      'server_metadata_change' =>
        en ? 'Approve server metadata change' : '确认服务器元数据修改',
      'monitor_state_change' =>
        en ? 'Approve monitor state change' : '确认监控状态变更',
      'local_import' => en ? 'Approve local import' : '确认本地导入操作',
      'local_log_change' => en ? 'Approve local log change' : '确认本地日志变更',
      'app_setting_change' => en ? 'Approve app settings change' : '确认应用设置变更',
      _ => en ? 'Approve tool action' : '确认工具操作',
    };
    final description = en
        ? 'The model wants to perform this action on ${pending.request.connectionName}. Reason: ${pending.request.reason}'
        : '模型想在 ${pending.request.connectionName} 上执行该操作。原因：${pending.request.reason}';
    final reject = en ? 'Reject' : '拒绝';
    final approve = en ? 'Approve' : '同意';
    final maxCommandHeight =
        (MediaQuery.sizeOf(context).height * 0.24).clamp(96.0, 180.0);
    final targetLabel = en ? 'Target' : '目标';
    final pathLabel = en ? 'Path' : '路径';
    final bytesLabel = en ? 'Bytes' : '字节';
    final previewLabel = en ? 'Preview' : '预览';
    final destructiveLabel = en ? 'This action is destructive.' : '这是一个破坏性操作。';
    final preview = pending.request.contentPreview?.trim();

    Widget metaRow(String label, String value) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.42)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.security_rounded,
                size: 20,
                color: colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.72),
              height: 1.35,
            ),
          ),
          if (pending.request.destructive) ...[
            const SizedBox(height: 8),
            Text(
              destructiveLabel,
              style: TextStyle(
                color: colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 8),
          metaRow(targetLabel, pending.request.connectionName),
          const SizedBox(height: 8),
          if (pending.request.targetPath != null) ...[
            metaRow(pathLabel, pending.request.targetPath!),
            const SizedBox(height: 8),
          ],
          if (pending.request.byteLength != null) ...[
            metaRow(bytesLabel, '${pending.request.byteLength}'),
            const SizedBox(height: 8),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxCommandHeight),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      pending.request.command,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (preview != null && preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              previewLabel,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SelectableText(
                    preview,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onReject,
                icon: const Icon(Icons.close_rounded),
                label: Text(reject),
              ),
              FilledButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check_rounded),
                label: Text(approve),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LlmSettingsScreen extends StatefulWidget {
  final AiConnectionSettings initialSettings;
  final List<String> initialModels;
  final List<String> initialBaseUrlHistory;
  final List<AiApiKeyHistoryEntry> initialApiKeyHistory;

  const _LlmSettingsScreen({
    required this.initialSettings,
    required this.initialModels,
    required this.initialBaseUrlHistory,
    required this.initialApiKeyHistory,
  });

  @override
  State<_LlmSettingsScreen> createState() => _LlmSettingsScreenState();
}

class _LlmSettingsScreenState extends State<_LlmSettingsScreen> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _apiKeyController;
  late List<String> _baseUrlHistory;
  late List<AiApiKeyHistoryEntry> _apiKeyHistory;
  late List<String> _models;
  late int _contextWindowTokens;
  late int _timeoutSeconds;
  late bool _deepSeekThinkingEnabled;
  late String _deepSeekReasoningEffort;
  late String _openAiReasoningEffort;
  late bool _webSearchEnabled;
  late int _webSearchMaxResults;
  String? _selectedApiKeyId;
  bool _loadingModels = false;
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _baseUrlController =
        TextEditingController(text: widget.initialSettings.baseUrl);
    _modelController =
        TextEditingController(text: widget.initialSettings.model);
    _apiKeyController = TextEditingController();
    _baseUrlHistory = List<String>.from(widget.initialBaseUrlHistory);
    _apiKeyHistory =
        List<AiApiKeyHistoryEntry>.from(widget.initialApiKeyHistory);
    _models = List<String>.from(widget.initialModels);
    _contextWindowTokens = widget.initialSettings.contextWindowTokens;
    _timeoutSeconds = widget.initialSettings.timeoutSeconds;
    _deepSeekThinkingEnabled = widget.initialSettings.deepSeekThinkingEnabled;
    _deepSeekReasoningEffort = widget.initialSettings.deepSeekReasoningEffort;
    _openAiReasoningEffort = widget.initialSettings.openAiReasoningEffort;
    _webSearchEnabled = widget.initialSettings.webSearchEnabled;
    _webSearchMaxResults = widget.initialSettings.webSearchMaxResults;
    _selectedApiKeyId = widget.initialSettings.activeApiKeyId;
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  static List<String> _modelOptions(String model) {
    return {..._defaultModels, if (model.trim().isNotEmpty) model.trim()}
        .toList()
      ..sort();
  }

  String? get _selectedApiKeyMasked {
    for (final entry in _apiKeyHistory) {
      if (entry.id == _selectedApiKeyId) {
        return entry.maskedValue;
      }
    }
    return null;
  }

  bool get _showsDeepSeekControls => isDeepSeekModelId(_modelController.text);

  bool get _showsOpenAiReasoningControls =>
      supportsOpenAiReasoningEffort(_modelController.text);

  Future<void> _applyBaseUrlSelection(String baseUrl) async {
    final storage = context.read<StorageService>();
    _baseUrlController.text = baseUrl;
    final cachedModels = await storage.loadCachedAiModels(baseUrl: baseUrl);
    if (!mounted) return;
    setState(() {
      _models = buildInitialModelOptions(
        currentModel: _modelController.text,
        cachedModels: cachedModels,
      );
      if (_models.isNotEmpty && !_models.contains(_modelController.text)) {
        _modelController.text = _models.first;
      }
    });
  }

  void _selectApiKeyHistoryEntry(String id) {
    if (!_apiKeyHistory.any((entry) => entry.id == id)) return;
    setState(() {
      _selectedApiKeyId = id;
      _apiKeyController.clear();
      _apiKeyHistory = [
        for (final entry in _apiKeyHistory)
          AiApiKeyHistoryEntry(
            id: entry.id,
            maskedValue: entry.maskedValue,
            isSelected: entry.id == id,
          ),
      ];
    });
  }

  Future<void> _deleteBaseUrlHistoryEntry(String baseUrl) async {
    final storage = context.read<StorageService>();
    await storage.removeAiBaseUrlHistoryEntry(baseUrl);
    if (!mounted) return;
    setState(() {
      _baseUrlHistory =
          _baseUrlHistory.where((item) => item != baseUrl).toList();
    });
  }

  Future<void> _deleteApiKeyHistoryEntry(String id) async {
    final storage = context.read<StorageService>();
    await storage.removeAiApiKeyHistoryEntry(id);
    final refreshed = await storage.loadAiApiKeyHistory();
    if (!mounted) return;
    final preferredSelectedId = _selectedApiKeyId;
    String? nextSelectedId = preferredSelectedId;
    if (nextSelectedId != null &&
        !refreshed.any((entry) => entry.id == nextSelectedId)) {
      nextSelectedId = null;
    }
    if (nextSelectedId == null) {
      for (final entry in refreshed) {
        if (entry.isSelected) {
          nextSelectedId = entry.id;
          break;
        }
      }
    }
    setState(() {
      _apiKeyHistory = [
        for (final entry in refreshed)
          AiApiKeyHistoryEntry(
            id: entry.id,
            maskedValue: entry.maskedValue,
            isSelected: entry.id == nextSelectedId,
          ),
      ];
      _selectedApiKeyId = nextSelectedId;
    });
  }

  Future<void> _openBaseUrlHistory(_AiStrings strings) async {
    final action = await showModalBottomSheet<_SettingsHistoryAction<String>>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: _HistoryActionSheet<String>(
          title: strings.baseUrlHistory,
          emptyText: strings.noBaseUrlHistory,
          deleteTooltip: strings.delete,
          items: _baseUrlHistory,
          labelBuilder: (value) => value,
          onSelect: (value) => Navigator.pop(
            sheetContext,
            _SettingsHistoryAction.select(value),
          ),
          onDelete: (value) => Navigator.pop(
            sheetContext,
            _SettingsHistoryAction.delete(value),
          ),
        ),
      ),
    );
    if (action == null) return;
    if (action.delete) {
      await _deleteBaseUrlHistoryEntry(action.value);
      return;
    }
    await _applyBaseUrlSelection(action.value);
  }

  Future<void> _openApiKeyHistory(_AiStrings strings) async {
    final action = await showModalBottomSheet<
        _SettingsHistoryAction<AiApiKeyHistoryEntry>>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: _HistoryActionSheet<AiApiKeyHistoryEntry>(
          title: strings.apiKeyHistory,
          emptyText: strings.noApiKeyHistory,
          deleteTooltip: strings.delete,
          items: _apiKeyHistory,
          labelBuilder: (entry) => entry.maskedValue,
          selectedValue: _selectedApiKeyId,
          valueKeyBuilder: (entry) => entry.id,
          onSelect: (entry) => Navigator.pop(
            sheetContext,
            _SettingsHistoryAction.select(entry),
          ),
          onDelete: (entry) => Navigator.pop(
            sheetContext,
            _SettingsHistoryAction.delete(entry),
          ),
        ),
      ),
    );
    if (action == null) return;
    if (action.delete) {
      await _deleteApiKeyHistoryEntry(action.value.id);
      return;
    }
    _selectApiKeyHistoryEntry(action.value.id);
  }

  Future<void> _refreshModels(_AiStrings strings) async {
    final storage = context.read<StorageService>();
    setState(() {
      _loadingModels = true;
      _errorText = null;
    });
    try {
      final service = LlmChatService(
        storageService: storage,
        toolService: AiToolService(
          storageService: storage,
          sshService: context.read<SshService>(),
          sftpService: context.read<SftpService>(),
          performanceMonitorToolService: PerformanceMonitorToolService(
            context.read<PerformanceMonitorService>(),
          ),
          appSettings: context.read<AppSettings>(),
        ),
      );
      final typedApiKey = _apiKeyController.text.trim();
      final resolvedApiKey = typedApiKey.isNotEmpty
          ? typedApiKey
          : (_selectedApiKeyId == null
              ? null
              : await storage.getAiApiKeyById(_selectedApiKeyId!));
      final fetched = await service.fetchModels(
        baseUrl: _baseUrlController.text.trim(),
        apiKey: resolvedApiKey,
      );
      final resolvedModels = resolveFetchedModelOptions(
        fetchedModels: fetched,
        fallbackModels: _models,
      );
      await storage.saveCachedAiModels(
        baseUrl: _baseUrlController.text.trim(),
        models: resolvedModels,
      );
      if (!mounted) return;
      setState(() {
        _models = resolvedModels;
        _loadingModels = false;
        if (_models.isNotEmpty && !_models.contains(_modelController.text)) {
          _modelController.text = _models.first;
        }
      });
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM model refresh failed in settings',
        error: e,
        stackTrace: stackTrace,
        details: 'baseUrl=${_baseUrlController.text.trim()}',
      );
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _errorText = strings.modelsFailed(e.toString());
      });
    }
  }

  Future<void> _save(_AiStrings strings) async {
    FocusScope.of(context).unfocus();
    final storage = context.read<StorageService>();
    final pending = _PendingAiSettings(
      baseUrl: _baseUrlController.text,
      model: _modelController.text,
      contextWindowTokens: _contextWindowTokens,
      timeoutSeconds: _timeoutSeconds,
      deepSeekThinkingEnabled: _deepSeekThinkingEnabled,
      deepSeekReasoningEffort: _deepSeekReasoningEffort,
      openAiReasoningEffort: _openAiReasoningEffort,
      webSearchEnabled: _webSearchEnabled,
      webSearchMaxResults: _webSearchMaxResults,
      apiKey: _apiKeyController.text,
      selectedApiKeyId: _selectedApiKeyId,
    );
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await storage.saveAiConnectionSettings(
        baseUrl: pending.baseUrl,
        model: pending.model,
        contextWindowTokens: pending.contextWindowTokens,
        timeoutSeconds: pending.timeoutSeconds,
        deepSeekThinkingEnabled: pending.deepSeekThinkingEnabled,
        deepSeekReasoningEffort: pending.deepSeekReasoningEffort,
        openAiReasoningEffort: pending.openAiReasoningEffort,
        webSearchEnabled: pending.webSearchEnabled,
        webSearchMaxResults: pending.webSearchMaxResults,
        apiKey: pending.apiKey,
        selectedApiKeyId: pending.selectedApiKeyId,
      );
      if (!mounted) return;
      Navigator.pop(context, pending);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM settings save failed',
        error: e,
        stackTrace: stackTrace,
        details:
            'baseUrl=${pending.baseUrl.trim()} model=${pending.model.trim()} apiKeyProvided=${pending.apiKey.trim().isNotEmpty}',
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = strings.failed(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _AiStrings(language);
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.settings),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(strings.cancel),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _saving ? null : () => _save(strings),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(strings.save),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            TextField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: strings.baseUrl,
                helperText: _baseUrlHistory.isEmpty
                    ? null
                    : strings.savedCount(_baseUrlHistory.length),
                suffixIcon: IconButton(
                  tooltip: strings.baseUrlHistory,
                  onPressed:
                      _saving ? null : () => _openBaseUrlHistory(strings),
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _models.contains(_modelController.text)
                        ? _modelController.text
                        : _models.first,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: strings.model),
                    selectedItemBuilder: (context) => [
                      for (final model in _models)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                          ),
                        ),
                    ],
                    items: [
                      for (final model in _models)
                        DropdownMenuItem(
                          value: model,
                          child: Text(
                            model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _modelController.text = value);
                            }
                          },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: strings.refreshModels,
                  onPressed: _loadingModels || _saving
                      ? null
                      : () => _refreshModels(strings),
                  icon: _loadingModels
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: _contextWindowTokens,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Context window'),
              items: [
                for (final value in AiContextWindowSize.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(AiContextWindowSize.label(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _contextWindowTokens = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: _timeoutSeconds,
              isExpanded: true,
              decoration: InputDecoration(labelText: strings.requestTimeout),
              items: [
                for (final value in AiRequestTimeout.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(AiRequestTimeout.label(value)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _timeoutSeconds = value);
                      }
                    },
            ),
            if (_showsDeepSeekControls) ...[
              const SizedBox(height: 14),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(strings.deepSeekThinking),
                subtitle: Text(strings.deepSeekThinkingHint),
                value: _deepSeekThinkingEnabled,
                onChanged: _saving
                    ? null
                    : (value) {
                        setState(() => _deepSeekThinkingEnabled = value);
                      },
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue:
                    DeepSeekReasoningEffort.normalize(_deepSeekReasoningEffort),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: strings.deepSeekReasoningEffort,
                ),
                items: [
                  for (final value in DeepSeekReasoningEffort.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(DeepSeekReasoningEffort.label(value)),
                    ),
                ],
                onChanged: _saving || !_deepSeekThinkingEnabled
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _deepSeekReasoningEffort = value);
                        }
                      },
              ),
            ],
            if (_showsOpenAiReasoningControls) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: OpenAiReasoningEffort.normalize(
                  _openAiReasoningEffort,
                ),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: strings.openAiReasoningEffort,
                  helperText: strings.openAiReasoningHint,
                ),
                items: [
                  for (final value in OpenAiReasoningEffort.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(OpenAiReasoningEffort.label(value)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _openAiReasoningEffort = value);
                        }
                      },
              ),
            ],
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.webSearch),
              subtitle: Text(strings.webSearchHint),
              value: _webSearchEnabled,
              onChanged: _saving
                  ? null
                  : (value) {
                      setState(() => _webSearchEnabled = value);
                    },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: AiWebSearchMaxResults.normalize(
                _webSearchMaxResults,
              ),
              isExpanded: true,
              decoration:
                  InputDecoration(labelText: strings.webSearchMaxResults),
              items: [
                for (final value in AiWebSearchMaxResults.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text('$value'),
                  ),
              ],
              onChanged: _saving || !_webSearchEnabled
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _webSearchMaxResults = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _apiKeyController,
              enabled: !_saving,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _selectedApiKeyMasked != null
                    ? strings.apiKeySaved
                    : strings.apiKeyRequired,
                helperText: _selectedApiKeyMasked != null
                    ? strings.apiKeySelected(_selectedApiKeyMasked!)
                    : (_apiKeyHistory.isNotEmpty
                        ? strings.apiKeyHistoryHint
                        : strings.apiKeyReplaceHint),
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  tooltip: strings.apiKeyHistory,
                  onPressed: _saving ? null : () => _openApiKeyHistory(strings),
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                ),
              ),
            ),
            if (_apiKeyHistory.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in _apiKeyHistory)
                    ChoiceChip(
                      label: Text(entry.maskedValue),
                      selected: entry.id == _selectedApiKeyId,
                      onSelected: _saving
                          ? null
                          : (_) => _selectApiKeyHistoryEntry(entry.id),
                    ),
                ],
              ),
              if (_selectedApiKeyMasked != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    strings.apiKeyMaskedPreview(_selectedApiKeyMasked!),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
            if (_errorText != null) ...[
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.36),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.error.withValues(alpha: 0.42),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _errorText!,
                    style: TextStyle(color: colorScheme.error),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsHistoryAction<T> {
  final T value;
  final bool delete;

  const _SettingsHistoryAction._({
    required this.value,
    required this.delete,
  });

  factory _SettingsHistoryAction.select(T value) {
    return _SettingsHistoryAction._(value: value, delete: false);
  }

  factory _SettingsHistoryAction.delete(T value) {
    return _SettingsHistoryAction._(value: value, delete: true);
  }
}

class _HistoryActionSheet<T> extends StatelessWidget {
  final String title;
  final String emptyText;
  final String deleteTooltip;
  final List<T> items;
  final String Function(T value) labelBuilder;
  final String? selectedValue;
  final String Function(T value)? valueKeyBuilder;
  final ValueChanged<T> onSelect;
  final ValueChanged<T> onDelete;

  const _HistoryActionSheet({
    required this.title,
    required this.emptyText,
    required this.deleteTooltip,
    required this.items,
    required this.labelBuilder,
    required this.onSelect,
    required this.onDelete,
    this.selectedValue,
    this.valueKeyBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                emptyText,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final itemKey = valueKeyBuilder?.call(item);
                  final selected = selectedValue != null &&
                      itemKey != null &&
                      itemKey == selectedValue;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: selected
                        ? Icon(
                            Icons.check_circle_rounded,
                            color: colorScheme.primary,
                          )
                        : const Icon(Icons.history_rounded),
                    title: Text(
                      labelBuilder(item),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => onSelect(item),
                    trailing: IconButton(
                      tooltip: deleteTooltip,
                      onPressed: () => onDelete(item),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PendingAiSettings {
  final String baseUrl;
  final String model;
  final int contextWindowTokens;
  final int timeoutSeconds;
  final bool deepSeekThinkingEnabled;
  final String deepSeekReasoningEffort;
  final String openAiReasoningEffort;
  final bool webSearchEnabled;
  final int webSearchMaxResults;
  final String apiKey;
  final String? selectedApiKeyId;

  const _PendingAiSettings({
    required this.baseUrl,
    required this.model,
    required this.contextWindowTokens,
    required this.timeoutSeconds,
    required this.deepSeekThinkingEnabled,
    required this.deepSeekReasoningEffort,
    required this.openAiReasoningEffort,
    required this.webSearchEnabled,
    required this.webSearchMaxResults,
    required this.apiKey,
    required this.selectedApiKeyId,
  });
}

class _AiStrings {
  final AppLanguage language;

  const _AiStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'LLM Assistant' : '大模型助手';
  String get welcome => _en
      ? 'Ask me about your servers, logs, status, or a remote file.'
      : '可以问我服务器状态、日志、远程文件等。';
  String get history => _en ? 'Chat history' : '聊天历史';
  String get newChat => _en ? 'New chat' : '新聊天';
  String get delete => _en ? 'Delete' : '删除';
  String get appSettings => _en ? 'App settings' : '应用设置';
  String get settings => _en ? 'LLM settings' : '大模型设置';
  String get send => _en ? 'Send' : '发送';
  String get stop => _en ? 'Stop' : '停止';
  String get stopped => _en ? '[Stopped by user]' : '[用户已终止]';
  String get baseUrl => _en ? 'Base URL' : 'Base URL';
  String get baseUrlHistory => _en ? 'Base URL history' : 'Base URL 历史';
  String get noBaseUrlHistory =>
      _en ? 'No saved Base URLs yet' : '还没有保存过 Base URL';
  String get model => _en ? 'Model' : '模型';
  String get refreshModels => _en ? 'Refresh models' : '刷新模型';
  String get requestTimeout => _en ? 'Request timeout' : '请求超时';
  String get deepSeekThinking => _en ? 'DeepSeek thinking' : 'DeepSeek 思考模式';
  String get deepSeekThinkingHint => _en
      ? 'Only sent to DeepSeek API hosts. Disable it for faster simple replies.'
      : '仅在 DeepSeek API 地址下发送。关闭后简单回复会更快。';
  String get deepSeekReasoningEffort =>
      _en ? 'DeepSeek reasoning effort' : 'DeepSeek 思考强度';
  String get webSearch => _en ? 'Local web search' : '本地网络搜索';
  String get webSearchHint => _en
      ? 'Expose a web_search tool that uses the current chat WebView on this device. No search API key is required.'
      : '通过当前聊天绑定的本机 WebView 给模型提供 web_search 工具，不需要搜索 API Key。';
  String get webSearchMaxResults => _en ? 'Search results per call' : '每次搜索结果数';
  String get openAiReasoningEffort =>
      _en ? 'OpenAI reasoning effort' : 'OpenAI 思考强度';
  String get openAiReasoningHint => _en
      ? 'Used for supported OpenAI reasoning models such as GPT-5 and o-series.'
      : '用于支持的 OpenAI 推理模型，例如 GPT-5 和 o 系列。';
  String get continueAfterTimeoutPrompt => _en
      ? 'Continue the previous answer. If a server command timed out, narrow the scope and continue with a smaller diagnostic step.'
      : '继续上一次回答。如果服务器命令超时，请缩小范围，用更小的诊断步骤继续。';
  String modelsFailed(String error) =>
      _en ? 'Unable to load models: $error' : '无法加载模型：$error';
  String savedCount(int count) => _en ? '$count saved' : '已保存 $count 条';
  String get apiKeySaved =>
      _en ? 'API Key (saved, leave blank)' : 'API Key（已保存，留空不改）';
  String get apiKeyRequired => _en ? 'API Key' : 'API Key';
  String get apiKeyHistory => _en ? 'API key history' : 'API Key 历史';
  String get noApiKeyHistory =>
      _en ? 'No saved API keys yet' : '还没有保存过 API Key';
  String get apiKeyReplaceHint => _en
      ? 'Leave this blank to keep the saved key, or enter a new key to replace it.'
      : '留空会保留已保存的 Key，输入新 Key 会替换当前 Key。';
  String get apiKeyHistoryHint => _en
      ? 'Choose a saved key from history, or enter a new one to add it.'
      : '可从历史中选择已保存 Key，或输入新 Key 后保存新增。';
  String apiKeySelected(String maskedValue) =>
      _en ? 'Current saved key: $maskedValue' : '当前已保存 Key：$maskedValue';
  String apiKeyMaskedPreview(String maskedValue) =>
      _en ? 'Selected key: $maskedValue' : '当前选择的 Key：$maskedValue';
  String get apiKeyClearPending => _en
      ? 'The saved API key will be removed when you save.'
      : '保存后会清除当前已保存的 API Key。';
  String get clearSavedApiKey => _en ? 'Clear saved API key' : '清除已保存的 API Key';
  String get keepSavedApiKey => _en ? 'Keep saved API key' : '保留已保存的 API Key';
  String get close => _en ? 'Close' : '关闭';
  String get cancel => _en ? 'Cancel' : '取消';
  String get save => _en ? 'Save' : '保存';
  String failed(Object error) => _en ? 'Failed: $error' : '失败：$error';
  String get commands => _en ? 'Commands' : '命令';
  String get commandUnknownHint => _en
      ? 'Type a command to use. Available: /compact, /tools.'
      : '输入以 / 开头的命令，如 /compact 或 /tools';
  String get commandUnknown => _en
      ? 'Unknown slash command.'
      : '未识别的斜杠命令。';
  String commandUnknownWithName(String command) =>
      _en ? 'Unknown command: /$command' : '未识别命令: /$command';
  String get commandCompact => _en
      ? 'Context compression is enabled for the next request.'
      : '已为下一次请求启用上下文压缩。';
  String commandToolsUpdated(int count) => _en
      ? 'Tool whitelist updated: $count selected.'
      : '工具白名单已更新：共选中 $count 个。';
  String commandToolsUnknown(List<String> unknown) => _en
      ? 'Unknown tool(s): ${unknown.join(', ')}'
      : '未识别工具：${unknown.join(', ')}';
  String get commandToolsLoadFailed => _en
      ? 'Unable to load available tools.'
      : '无法加载可用工具。';
  String get commandToolsNoTools => _en
      ? 'No tools are currently available.'
      : '当前无可用工具。';
  String get commandToolsSearch => _en ? 'Search tools' : '搜索工具';
  String get commandToolsNoResult =>
      _en ? 'No tools match the search.' : '未找到匹配的工具。';
}
