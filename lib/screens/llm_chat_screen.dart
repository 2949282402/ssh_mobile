import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ai_tool_service.dart';
import '../services/app_settings.dart';
import '../services/llm_chat_service.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';

class LlmChatScreen extends StatefulWidget {
  const LlmChatScreen({super.key});

  @override
  State<LlmChatScreen> createState() => _LlmChatScreenState();
}

class _LlmChatScreenState extends State<LlmChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [
    const _ChatMessage(
      role: _ChatRole.assistant,
      text:
          'I can inspect saved servers, run safe read-only commands, and browse small text files through SFTP.',
    ),
  ];
  bool _sending = false;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = _AiStrings(context.watch<AppSettings>().language);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                bottom: BorderSide(color: colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.smart_toy_outlined, color: colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.title,
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
                          color: colorScheme.onSurface.withValues(alpha: 0.62),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
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
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
              itemCount: _messages.length,
              itemBuilder: (context, index) => _MessageBubble(
                message: _messages[index],
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
                      decoration: InputDecoration(
                        hintText: strings.inputHint,
                      ),
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
    if (text.isEmpty || _sending) return;

    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    final sftp = context.read<SftpService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!settings.hasApiKey) {
      if (!context.mounted) return;
      await _showSettings(context, strings);
      return;
    }

    setState(() {
      _messages.add(_ChatMessage(role: _ChatRole.user, text: text));
      _sending = true;
      _inputController.clear();
    });
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
      final answer = await service.send(
        messages: _messages
            .where((message) => message.role != _ChatRole.error)
            .map(
              (message) => {
                'role': message.role == _ChatRole.user ? 'user' : 'assistant',
                'content': message.text,
              },
            )
            .toList(),
      );
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(role: _ChatRole.assistant, text: answer));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage(role: _ChatRole.error, text: strings.failed(e)),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _showSettings(BuildContext context, _AiStrings strings) async {
    final storage = context.read<StorageService>();
    final settings = await storage.loadAiConnectionSettings();
    if (!context.mounted) return;

    final baseUrlController = TextEditingController(text: settings.baseUrl);
    final modelController = TextEditingController(text: settings.model);
    final apiKeyController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
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
              TextField(
                controller: modelController,
                decoration: InputDecoration(labelText: strings.model),
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
            onPressed: () async {
              await storage.saveAiConnectionSettings(
                baseUrl: baseUrlController.text,
                model: modelController.text,
                apiKey: apiKeyController.text,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(strings.save),
          ),
        ],
      ),
    );

    baseUrlController.dispose();
    modelController.dispose();
    apiKeyController.dispose();
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
}

class _MessageBubble extends StatelessWidget {
  final _ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.role == _ChatRole.user;
    final isError = message.role == _ChatRole.error;
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
          child: SelectableText(
            message.text,
            style: TextStyle(
              color: isError ? colorScheme.error : colorScheme.onSurface,
              height: 1.35,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatMessage {
  final _ChatRole role;
  final String text;

  const _ChatMessage({
    required this.role,
    required this.text,
  });
}

enum _ChatRole { user, assistant, error }

class _AiStrings {
  final AppLanguage language;

  const _AiStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'LLM Assistant' : '大模型助手';
  String get nav => _en ? 'AI' : 'AI';
  String get subtitle => _en
      ? 'OpenAI-compatible tools for SSH and SFTP'
      : '通过 OpenAI 格式调用 SSH/SFTP 工具';
  String get settings => _en ? 'LLM settings' : '大模型设置';
  String get inputHint => _en
      ? 'Ask about a server, logs, status, or a remote file...'
      : '询问服务器状态、日志、远程文件等...';
  String get send => _en ? 'Send' : '发送';
  String get baseUrl => _en ? 'Base URL' : 'Base URL';
  String get model => _en ? 'Model' : '模型';
  String get apiKeySaved =>
      _en ? 'API Key (saved, leave blank)' : 'API Key（已保存，留空不改）';
  String get apiKeyRequired => _en ? 'API Key' : 'API Key';
  String get cancel => _en ? 'Cancel' : '取消';
  String get save => _en ? 'Save' : '保存';
  String failed(Object error) => _en ? 'Failed: $error' : '失败：$error';
}
