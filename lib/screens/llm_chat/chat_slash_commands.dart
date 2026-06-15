// ignore_for_file: invalid_use_of_protected_member
part of '../llm_chat_screen.dart';

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
  _SlashCommandMeta(
    command: '/plan',
    summary: 'Toggle plan mode or run a plan task.',
    details: 'Design a structured execution plan without modifying server state.',
  ),
];

extension _ChatSlashCommands on _LlmChatScreenState {
  static const int _maxToolSelectorHeightPercent = 78;

  bool get _shouldShowSlashCommandPanel {
    final text = _inputController.text;
    if (!text.startsWith('/')) return false;

    final firstSpace = text.indexOf(' ');
    if (firstSpace == -1) {
      return true;
    }

    final selection = _inputController.selection;
    if (selection.isValid &&
        selection.isCollapsed &&
        selection.baseOffset <= firstSpace) {
      return true;
    }

    if (text == '/' || text.startsWith('/ ')) return true;

    return false;
  }

  List<_SlashCommandMeta> get _filteredSlashCommands {
    final text = _inputController.text;
    if (text.isEmpty || !text.startsWith('/')) return const [];

    final firstSpace = text.indexOf(' ');
    final query = firstSpace == -1
        ? text.substring(1).toLowerCase()
        : text.substring(1, firstSpace).toLowerCase();

    if (query.isEmpty) {
      return _defaultSlashCommands;
    }
    return _defaultSlashCommands
        .where((cmd) => cmd.command.substring(1).toLowerCase().contains(query))
        .toList();
  }

  Widget _buildSlashCommandPanel(BuildContext context, _AiStrings strings) {
    final suggestions = _filteredSlashCommands;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final command in suggestions)
                ListTile(
                  dense: true,
                  title: Text(
                    command.command,
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    command.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    final text = _inputController.text;
                    final firstSpace = text.indexOf(' ');
                    final arguments =
                        firstSpace == -1 ? '' : text.substring(firstSpace + 1);

                    final bool needsSpaceSuffix = command.command == '/tools' ||
                        command.command == '/plan';
                    final canonicalCmd = needsSpaceSuffix
                        ? '${command.command} '
                        : command.command;

                    final nextText = '$canonicalCmd$arguments';
                    _inputController.text = nextText;

                    final nextCursorOffset =
                        arguments.isEmpty ? nextText.length : canonicalCmd.length;

                    setState(() => _inputController.selection =
                        TextSelection.collapsed(offset: nextCursorOffset));
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
          _inputController.clear();
        }
        return handled;
      case 'plan':
        final handled = await _executePlanCommand(
          chatId: chatId,
          arguments: parsed.arguments,
          strings: strings,
        );
        if (handled) {
          _inputController.clear();
        }
        return handled;
      case 'skills':
        if (!context.mounted) {
          return false;
        }
        await Navigator.of(context).pushNamed('/ai-skills');
        if (!mounted) {
          return false;
        }
        _showCommandFeedback(strings.commandSkillsOpened, context);
        return true;
    }
    if (!mounted) return false;
    _showCommandFeedback(strings.commandUnknown, context);
    return false;
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

  Future<bool> _executePlanCommand({
    required String chatId,
    required String arguments,
    required _AiStrings strings,
  }) async {
    final activeChat = _activeChat;
    if (activeChat == null || activeChat.id != chatId) return false;
    final storage = context.read<StorageService>();

    if (arguments.trim().isEmpty) {
      final nextPlanMode = !activeChat.planMode;
      final updatedChat = activeChat.copyWith(planMode: nextPlanMode);

      setState(() {
        _replaceChat(updatedChat);
      });
      await storage.saveAiChat(updatedChat);

      if (!mounted || !context.mounted) return true;

      final msg = strings.language == AppLanguage.en
          ? (nextPlanMode ? 'Plan Mode Enabled' : 'Plan Mode Disabled')
          : (nextPlanMode ? '规划模式已启用' : '规划模式已关闭');
      _showCommandFeedback(msg, context);
      return true;
    }

    final updatedChat = activeChat.copyWith(planMode: true);
    setState(() {
      _replaceChat(updatedChat);
    });
    await storage.saveAiChat(updatedChat);

    if (!mounted || !context.mounted) return true;

    scheduleMicrotask(() {
      if (mounted) {
        _sendText(context, strings, text: arguments, clearInput: true);
      }
    });
    return true;
  }
}
