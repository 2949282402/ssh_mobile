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

class _LlmChatScreenState extends State<LlmChatScreen>
    with AutomaticKeepAliveClientMixin<LlmChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<AiChatRecord> _chats = const [];
  String? _activeChatId;
  bool _loading = true;
  bool _sending = false;

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
                          strings.subtitle,
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
                ),
              ),
            ),
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
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(hintText: strings.inputHint),
                      onSubmitted: (_) => _send(context, strings),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: strings.send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    onPressed: _sending ? null : () => _send(context, strings),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _send(BuildContext context, _AiStrings strings) async {
    final text = _inputController.text.trim();
    final activeChat = _activeChat;
    if (text.isEmpty || _sending || activeChat == null) return;

    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    final sftp = context.read<SftpService>();
    final settings = await storage.loadAiConnectionSettings();
    final currentModel = settings.model.trim();
    if (!settings.hasApiKey) {
      if (!context.mounted) return;
      await _showSettings(context, strings);
      return;
    }

    final chatId = activeChat.id;
    final now = DateTime.now();
    final userMessage = AiChatMessageRecord(
      role: 'user',
      text: text,
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
      await for (final chunk in service.stream(
        modelOverride: currentModel.isNotEmpty ? currentModel : nextChat.model,
        messages: nextMessages
            .where((message) => message.role != 'error')
            .where((message) => message.text.isNotEmpty)
            .where((message) => message != assistantMessage)
            .map(
              (message) => {
                'role': message.role == 'user' ? 'user' : 'assistant',
                'content': message.text,
              },
            )
            .toList(),
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
          streamedMessages[assistantIndex] = AiChatMessageRecord(
            role: 'assistant',
            text: answer.toString(),
            createdAt: assistantMessage.createdAt,
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
      final currentChat = _chatById(chatId) ?? nextChat;
      final completedMessages = [...currentChat.messages];
      final assistantIndex = completedMessages.indexWhere(
        (message) =>
            message.role == 'assistant' &&
            message.createdAt == assistantMessage.createdAt,
      );
      if (assistantIndex >= 0) {
        completedMessages[assistantIndex] = AiChatMessageRecord(
          role: 'assistant',
          text: answer.toString(),
          createdAt: assistantMessage.createdAt,
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
      final currentChat = _chatById(chatId) ?? nextChat;
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
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
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
      apiKey: nextSettings.apiKey,
    );
    if (!mounted) return;
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

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final isError = message.role == 'error';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
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
                    color: isError ? colorScheme.error : colorScheme.onSurface,
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
      ),
    );
  }
}

class _PendingAiSettings {
  final String baseUrl;
  final String model;
  final String apiKey;

  const _PendingAiSettings({
    required this.baseUrl,
    required this.model,
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
