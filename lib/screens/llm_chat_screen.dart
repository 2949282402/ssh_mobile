import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../services/ai_tool_service.dart';
import '../services/app_settings.dart';
import '../services/llm_chat_service.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';

const List<String> _defaultModels = [
  'deepseek-v4-flash',
  'deepseek-v4-pro',
];

class LlmChatScreen extends StatefulWidget {
  const LlmChatScreen({super.key});

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
}

extension _AiToolbarActionStrings on _AiStrings {
  String get serverTarget => language == AppLanguage.en ? 'Server' : '服务器';
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

class _LlmChatScreenState extends State<LlmChatScreen>
    with AutomaticKeepAliveClientMixin<LlmChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<AiChatRecord> _chats = const [];
  String? _activeChatId;
  _PendingToolApproval? _pendingApproval;
  int _contextWindowTokens = AiContextWindowSize.k259;
  bool _loading = true;
  bool _sending = false;
  bool _toolsExpanded = false;
  String? _selectedConnectionId;
  String? _selectedSkillId;

  AiChatRecord? get _activeChat {
    for (final chat in _chats) {
      if (chat.id == _activeChatId) return chat;
    }
    return _chats.isEmpty ? null : _chats.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadChats());
  }

  @override
  void dispose() {
    if (_pendingApproval?.completer.isCompleted == false) {
      _pendingApproval!.completer.complete(
        const AiToolApprovalDecision.rejected(),
      );
    }
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadChats() async {
    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    final chats = await storage.loadAiChats();
    if (!mounted) return;
    setState(() {
      _chats = chats.isEmpty ? [_newChatRecord(settings.model)] : chats;
      _activeChatId = _chats.first.id;
      _contextWindowTokens = settings.contextWindowTokens;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final strings = _AiStrings(context.watch<AppSettings>().language);
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
    final contextTokens = _estimatedContextTokens(activeChat.messages);
    final contextPercent =
        _contextWindowTokens <= 0 ? 0.0 : contextTokens / _contextWindowTokens;

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            decoration: BoxDecoration(
              color: colorScheme.surface,
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
                          '${strings.subtitle} · ${_contextUsage(contextTokens, _contextWindowTokens, contextPercent)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                colorScheme.onSurface.withValues(alpha: 0.62),
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
                  onPressed: _sending ? null : () => _createChatFromSettings(),
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
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                itemCount: visibleMessages.length,
                itemBuilder: (context, index) => _MessageBubble(
                  message: visibleMessages[index],
                  canAct: !_sending && activeChat.messages == visibleMessages,
                  onEditUser: visibleMessages[index].role == 'user'
                      ? () => _editUserMessage(index, strings)
                      : null,
                  onRegenerate: visibleMessages[index].role == 'assistant'
                      ? () => _regenerateAssistant(index)
                      : null,
                  onBranch: visibleMessages[index].role == 'assistant'
                      ? () => _branchFromAssistant(index, strings)
                      : null,
                ),
              ),
            ),
          ),
          if (_pendingApproval?.chatId == activeChat.id)
            _ToolApprovalPanel(
              pending: _pendingApproval!,
              strings: strings,
              onApprove: () => _resolvePendingApproval(approved: true),
              onReject: () => _resolvePendingApproval(approved: false),
            ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border(
                  top: BorderSide(color: colorScheme.outlineVariant),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _toolsExpanded
                        ? _ChatToolsBar(
                            key: const ValueKey('chat-tools-bar'),
                            tools: _availableAiTools(),
                            skillsLabel: strings.skills,
                            serverLabel: _selectedServerLabel(strings),
                            skillLabel: _selectedSkillLabel(strings),
                            onToolTap: (tool) => _showToolDetails(tool),
                            onServerTap: () => _selectTargetServer(strings),
                            onTemplateTap: () => _selectPromptTemplate(strings),
                            onQuickSkillTap: () => _selectQuickSkill(strings),
                            onSkillsTap: () {
                              Navigator.pushNamed(context, '/ai-skills');
                            },
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('chat-tools-empty'),
                          ),
                  ),
                  if (_toolsExpanded) const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.newline,
                          decoration:
                              InputDecoration(hintText: strings.inputHint),
                          onSubmitted: (_) => _send(context, strings),
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
                          setState(() => _toolsExpanded = !_toolsExpanded);
                        },
                      ),
                      const SizedBox(width: 4),
                      IconButton.filled(
                        tooltip: strings.send,
                        icon: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send_rounded),
                        onPressed:
                            _sending ? null : () => _send(context, strings),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<AiTool> _availableAiTools() {
    // Read the catalog from AiToolService so the UI follows tool changes
    // without maintaining a second hardcoded list.
    return AiToolService(
      storageService: context.read<StorageService>(),
      sshService: context.read<SshService>(),
      sftpService: context.read<SftpService>(),
    ).tools;
  }

  Future<void> _showToolDetails(AiTool tool) async {
    final strings = _AiStrings(context.read<AppSettings>().language);
    final parameters = const JsonEncoder.withIndent('  ').convert({
      'properties': tool.properties,
      'required': tool.required,
    });
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tool.name),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tool.description,
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurface,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  parameters,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.close),
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

  String _selectedSkillLabel(_AiStrings strings) {
    final id = _selectedSkillId;
    if (id == null) return strings.quickSkill;
    return strings.quickSkillActive;
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

  Future<void> _selectPromptTemplate(_AiStrings strings) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final template in _PromptTemplate.defaults(strings))
              ListTile(
                leading: const Icon(Icons.text_snippet_outlined),
                title: Text(template.title),
                subtitle: Text(
                  template.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(ctx, template.text),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final current = _inputController.text.trim();
    _inputController.text =
        current.isEmpty ? selected : '$current\n\n$selected';
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
  }

  Future<void> _selectQuickSkill(_AiStrings strings) async {
    final skills = (await context.read<StorageService>().loadAiSkills())
        .where((skill) => skill.enabled)
        .toList();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.clear_rounded),
              title: Text(strings.noQuickSkill),
              onTap: () => Navigator.pop(ctx, null),
            ),
            if (skills.isEmpty)
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text(strings.noSkills),
                onTap: () => Navigator.pop(ctx),
              ),
            for (final skill in skills)
              ListTile(
                leading: Icon(
                  skill.id == _selectedSkillId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(skill.name),
                subtitle: Text(
                  skill.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(ctx, skill.id),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _selectedSkillId = selected);
  }

  Future<void> _send(BuildContext context, _AiStrings strings) async {
    final text = _inputController.text.trim();
    final activeChat = _activeChat;
    if (text.isEmpty || _sending || activeChat == null) return;

    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    final currentModel = settings.model.trim();
    if (!settings.hasApiKey) {
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
      _inputController.clear();
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
      ),
    );

    try {
      final answer = StringBuffer();
      LlmRunStats? runStats;
      await for (final chunk in service.stream(
        modelOverride: model,
        onStats: (stats) => runStats = stats,
        onTrace: (event) {
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
        messages: _messagesForRequest(
          requestMessages,
          placeholder: assistantMessage,
        ),
      )) {
        answer.write(chunk);
        if (!mounted) return;
        final currentChat = _chatById(chatId);
        if (currentChat == null) continue;
        final streamedMessages = [...currentChat.messages];
        final assistantIndex = streamedMessages.indexWhere(
          (message) =>
              message.role == 'assistant' &&
              message.createdAt == assistantMessage.createdAt,
        );
        if (assistantIndex >= 0) {
          streamedMessages[assistantIndex] =
              streamedMessages[assistantIndex].copyWith(
            text: answer.toString(),
          );
          setState(() {
            _replaceChat(
              currentChat.copyWith(
                messages: streamedMessages,
                updatedAt: DateTime.now(),
              ),
            );
          });
          _scrollToBottom();
        }
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
          contextText: _contextTextForAssistant(answer.toString()),
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
      setState(() => _replaceChat(answeredChat));
      await storage.saveAiChat(answeredChat);
    } catch (e) {
      if (!mounted) return;
      final currentChat = _chatById(chatId) ?? initialChat;
      final errorMessages = [...currentChat.messages];
      final assistantIndex = errorMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0 && errorMessages[assistantIndex].text.isEmpty) {
        errorMessages.removeAt(assistantIndex);
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
      setState(() => _replaceChat(errorChat));
      await storage.saveAiChat(errorChat);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          if (_pendingApproval?.chatId == chatId) {
            _pendingApproval = null;
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
    if (editedText == null || editedText.trim().isEmpty) return;
    if (!mounted) return;

    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      if (mounted) await _showSettings(context, strings);
      return;
    }
    if (!mounted) return;

    final now = DateTime.now();
    final editedUser = target.copyWith(
      text: editedText.trim(),
      createdAt: now,
    );
    final assistantMessage = AiChatMessageRecord(
      role: 'assistant',
      text: '',
      createdAt: now,
    );
    final nextMessages = [
      ...activeChat.messages.take(messageIndex),
      editedUser,
      assistantMessage,
    ];
    final nextModel =
        settings.model.trim().isNotEmpty ? settings.model : activeChat.model;
    final nextChat = activeChat.copyWith(
      title: messageIndex == 0 ? _titleFrom(editedText, strings) : null,
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
            decoration: InputDecoration(hintText: strings.inputHint),
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
      _activeChatId = branch.id;
    });
    await context.read<StorageService>().saveAiChat(branch);
    _scrollToBottom();
  }

  Future<void> _showHistory(BuildContext context, _AiStrings strings) async {
    final colorScheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.history,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: strings.newChat,
                    icon: const Icon(Icons.add_rounded),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _createChatFromSettings();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                itemCount: _chats.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final chat = _chats[index];
                  final selected = chat.id == _activeChatId;
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
                      _formatTime(chat.updatedAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: strings.delete,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _chats.length <= 1
                          ? null
                          : () async {
                              await _deleteChat(chat.id);
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                    ),
                    onTap: () {
                      setState(() => _activeChatId = chat.id);
                      Navigator.pop(ctx);
                      _scrollToBottom();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSettings(BuildContext context, _AiStrings strings) async {
    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!context.mounted) return;

    final baseUrlController = TextEditingController(text: settings.baseUrl);
    final modelController = TextEditingController(text: settings.model);
    final apiKeyController = TextEditingController();
    var models = _modelOptions(settings.model);
    var contextWindowTokens = settings.contextWindowTokens;
    var loadingModels = false;
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
          ),
        );
        final fetched = await service.fetchModels(
          baseUrl: baseUrlController.text.trim(),
          apiKey: typedApiKey.isEmpty ? null : typedApiKey,
        );
        if (!ctx.mounted) return;
        setDialogState(() {
          models = {..._defaultModels, ...fetched}.toList()..sort();
          loadingModels = false;
          if (models.isNotEmpty && !models.contains(modelController.text)) {
            modelController.text = models.first;
          }
        });
      } catch (e) {
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
                              child: CircularProgressIndicator(strokeWidth: 2),
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  ctx,
                  _PendingAiSettings(
                    baseUrl: baseUrlController.text,
                    model: modelController.text,
                    contextWindowTokens: contextWindowTokens,
                    apiKey: apiKeyController.text,
                  ),
                );
              },
              child: Text(strings.save),
            ),
          ],
        ),
      ),
    );

    baseUrlController.dispose();
    modelController.dispose();
    apiKeyController.dispose();

    if (nextSettings == null) return;
    await storage.saveAiConnectionSettings(
      baseUrl: nextSettings.baseUrl,
      model: nextSettings.model,
      contextWindowTokens: nextSettings.contextWindowTokens,
      apiKey: nextSettings.apiKey,
    );
    if (!mounted) return;
    setState(() => _contextWindowTokens = nextSettings.contextWindowTokens);
    final activeChat = _activeChat;
    final nextModel = nextSettings.model.trim();
    if (activeChat != null &&
        nextModel.isNotEmpty &&
        activeChat.model != nextModel) {
      await _updateActiveChat(
        activeChat.copyWith(
          model: nextModel,
          updatedAt: DateTime.now(),
        ),
      );
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
        AiMessageTrace(
          kind: event.kind,
          title: event.title,
          content: event.content,
          createdAt: DateTime.now(),
        ),
      ],
    );
    setState(() {
      _replaceChat(
        currentChat.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        ),
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
      _chats = [chat, ..._chats];
      _activeChatId = chat.id;
    });
    context.read<StorageService>().saveAiChat(chat);
    _scrollToBottom();
  }

  Future<void> _deleteChat(String id) async {
    if (_chats.length <= 1) return;
    final nextChats = _chats.where((chat) => chat.id != id).toList();
    setState(() {
      _chats = nextChats;
      if (_activeChatId == id) _activeChatId = nextChats.first.id;
    });
    await context.read<StorageService>().deleteAiChat(id);
  }

  Future<void> _updateActiveChat(AiChatRecord chat) async {
    setState(() => _replaceChat(chat));
    await context.read<StorageService>().saveAiChat(chat);
  }

  void _replaceChat(AiChatRecord chat) {
    final chats = [..._chats];
    final index = chats.indexWhere((item) => item.id == chat.id);
    if (index >= 0) {
      chats[index] = chat;
    } else {
      chats.insert(0, chat);
    }
    chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _chats = chats;
    _activeChatId = chat.id;
  }

  AiChatRecord? _chatById(String id) {
    for (final chat in _chats) {
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
          return {
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
      return message.contextText ?? _contextTextForAssistant(message.text);
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
    final skillId = _selectedSkillId;
    if (skillId != null) {
      final skills = await context.read<StorageService>().loadAiSkills();
      for (final skill in skills) {
        if (skill.id == skillId && skill.enabled) {
          lines.add(
            'Temporary user-selected skill for this request:\nName: ${skill.name}\nDescription: ${skill.description}\nContent:\n${skill.content}',
          );
          break;
        }
      }
    }
    if (lines.isEmpty) return null;
    return '${lines.join('\n\n')}\n\nUser request:\n$text';
  }

  String _contextTextForAssistant(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    if (!_shouldOmitAssistantBody(trimmed)) return trimmed;

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

  int _estimatedContextTokens(List<AiChatMessageRecord> messages) {
    final mapped = _messagesForRequest(messages);
    mapped.insert(0, {'role': 'system', 'content': 'system'});
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
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

class _MessageBubble extends StatelessWidget {
  final AiChatMessageRecord message;
  final bool canAct;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;

  const _MessageBubble({
    required this.message,
    this.canAct = false,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final isError = message.role == 'error';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.all(12),
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
                      : colorScheme.outlineVariant,
                ),
              ),
              child: isUser || isError
                  ? SelectableText(
                      message.text,
                      style: TextStyle(
                        color:
                            isError ? colorScheme.error : colorScheme.onSurface,
                        height: 1.35,
                      ),
                    )
                  : MarkdownBody(
                      data: message.text.isEmpty ? '...' : message.text,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(
                        Theme.of(context),
                      ).copyWith(
                        p: TextStyle(
                          color: colorScheme.onSurface,
                          height: 1.35,
                        ),
                        code: TextStyle(
                          color: colorScheme.onSurface,
                          backgroundColor:
                              colorScheme.surfaceContainerHighest.withValues(
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
                    ),
            ),
            if (canAct &&
                (onEditUser != null ||
                    onRegenerate != null ||
                    onBranch != null))
              _MessageActions(
                isUser: isUser,
                onEditUser: onEditUser,
                onRegenerate: onRegenerate,
                onBranch: onBranch,
              ),
            if (!isUser && !isError && message.traces.isNotEmpty)
              _TracePanel(traces: message.traces),
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

class _ChatToolsBar extends StatelessWidget {
  final List<AiTool> tools;
  final String skillsLabel;
  final String serverLabel;
  final String skillLabel;
  final ValueChanged<AiTool> onToolTap;
  final VoidCallback onServerTap;
  final VoidCallback onTemplateTap;
  final VoidCallback onQuickSkillTap;
  final VoidCallback onSkillsTap;

  const _ChatToolsBar({
    super.key,
    required this.tools,
    required this.skillsLabel,
    required this.serverLabel,
    required this.skillLabel,
    required this.onToolTap,
    required this.onServerTap,
    required this.onTemplateTap,
    required this.onQuickSkillTap,
    required this.onSkillsTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ActionChip(
            avatar: const Icon(Icons.dns_outlined, size: 16),
            label: Text(serverLabel),
            onPressed: onServerTap,
          ),
          ActionChip(
            avatar: const Icon(Icons.text_snippet_outlined, size: 16),
            label: const Text('Templates'),
            onPressed: onTemplateTap,
          ),
          ActionChip(
            avatar: const Icon(Icons.bolt_outlined, size: 16),
            label: Text(skillLabel),
            onPressed: onQuickSkillTap,
          ),
          ActionChip(
            avatar: const Icon(Icons.auto_awesome_outlined, size: 16),
            label: Text(skillsLabel),
            onPressed: onSkillsTap,
          ),
          for (final tool in tools)
            ActionChip(
              avatar: const Icon(Icons.construction_rounded, size: 16),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(
                  tool.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onPressed: () => onToolTap(tool),
            ),
        ],
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
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;

  const _MessageActions({
    required this.isUser,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final children = <Widget>[
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
          tooltip: 'Regenerate',
          icon: Icons.refresh_rounded,
          onPressed: onRegenerate,
        ),
      if (onBranch != null)
        _actionButton(
          context,
          tooltip: 'Branch from here',
          icon: Icons.call_split_rounded,
          onPressed: onBranch,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, bottom: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
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

  const _TracePanel({required this.traces});

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
              _TraceEntry(trace: traces[i], index: i + 1),
          ],
        ),
      ),
    );
  }
}

class _TraceEntry extends StatelessWidget {
  final AiMessageTrace trace;
  final int index;

  const _TraceEntry({
    required this.trace,
    required this.index,
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
              child: SelectableText(
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
        return trace.title.contains('approved') ? '写命令已同意' : '写命令已拒绝';
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
    final title = en ? 'Approve server write command' : '确认执行服务器写命令';
    final description = en
        ? 'The model wants to run a command that may change server state on ${pending.request.connectionName}. Reason: ${pending.request.reason}'
        : '模型想在 ${pending.request.connectionName} 上执行可能修改服务器状态的命令。原因：${pending.request.reason}';
    final reject = en ? 'Reject' : '拒绝';
    final approve = en ? 'Approve' : '同意';
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
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.72),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: SelectableText(
              pending.request.command,
              style: TextStyle(
                fontFamily: 'monospace',
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: onReject,
                icon: const Icon(Icons.close_rounded),
                label: Text(reject),
              ),
              const SizedBox(width: 8),
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

class _PendingAiSettings {
  final String baseUrl;
  final String model;
  final int contextWindowTokens;
  final String apiKey;

  const _PendingAiSettings({
    required this.baseUrl,
    required this.model,
    required this.contextWindowTokens,
    required this.apiKey,
  });
}

class _AiStrings {
  final AppLanguage language;

  const _AiStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'LLM Assistant' : '大模型助手';
  String get subtitle => _en
      ? 'OpenAI-compatible tools for SSH and SFTP'
      : '通过 OpenAI 格式调用 SSH/SFTP 工具';
  String get welcome => _en
      ? 'Ask me about your servers, logs, status, or a remote file.'
      : '可以问我服务器状态、日志、远程文件等。';
  String get history => _en ? 'Chat history' : '聊天历史';
  String get newChat => _en ? 'New chat' : '新聊天';
  String get delete => _en ? 'Delete' : '删除';
  String get settings => _en ? 'LLM settings' : '大模型设置';
  String get inputHint => _en
      ? 'Ask about a server, logs, status, or a remote file...'
      : '询问服务器状态、日志、远程文件等...';
  String get send => _en ? 'Send' : '发送';
  String get baseUrl => _en ? 'Base URL' : 'Base URL';
  String get model => _en ? 'Model' : '模型';
  String get refreshModels => _en ? 'Refresh models' : '刷新模型';
  String modelsFailed(String error) =>
      _en ? 'Unable to load models: $error' : '无法加载模型：$error';
  String get apiKeySaved =>
      _en ? 'API Key (saved, leave blank)' : 'API Key（已保存，留空不改）';
  String get apiKeyRequired => _en ? 'API Key' : 'API Key';
  String get cancel => _en ? 'Cancel' : '取消';
  String get save => _en ? 'Save' : '保存';
  String failed(Object error) => _en ? 'Failed: $error' : '失败：$error';
}
