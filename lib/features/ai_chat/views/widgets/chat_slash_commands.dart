// ignore_for_file: invalid_use_of_protected_member
part of '../llm_chat_screen.dart';

class SlashCommandMeta {
  final String command;
  final String summary;
  final String details;

  const SlashCommandMeta({
    required this.command,
    required this.summary,
    required this.details,
  });
}

class ToolOption {
  final String name;
  final String description;

  const ToolOption({
    required this.name,
    required this.description,
  });
}

const List<SlashCommandMeta> _defaultSlashCommands = [
  SlashCommandMeta(
    command: '/compact',
    summary: 'Force compression on the next request.',
    details: 'The next AI request will compress context before sending.',
  ),
  SlashCommandMeta(
    command: '/tools',
    summary: 'Limit tools for this chat.',
    details: 'Restrict which tools the model can call in the current chat.',
  ),
  SlashCommandMeta(
    command: '/skills',
    summary: 'Open and manage local AI skills.',
    details: 'View saved Skills and enable or disable them.',
  ),
  SlashCommandMeta(
    command: '/plan',
    summary: 'Enable Plan Mode and optionally submit a request.',
    details:
        'Enter read-only planning mode. If a request is provided, it will be sent in Plan Mode.',
  ),
];

class ChatSlashCommandsPanel extends StatelessWidget {
  final TextEditingController inputController;
  final AiStrings strings;
  final VoidCallback onStateChanged;

  const ChatSlashCommandsPanel({
    super.key,
    required this.inputController,
    required this.strings,
    required this.onStateChanged,
  });

  bool get _shouldShowPanel {
    final text = inputController.text;
    if (!text.startsWith('/')) return false;

    final firstSpace = text.indexOf(' ');
    if (firstSpace == -1) {
      return true;
    }

    final selection = inputController.selection;
    if (selection.isValid &&
        selection.isCollapsed &&
        selection.baseOffset <= firstSpace) {
      return true;
    }

    if (text == '/' || text.startsWith('/ ')) return true;

    return false;
  }

  List<SlashCommandMeta> get _filteredSlashCommands {
    final text = inputController.text;
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

  @override
  Widget build(BuildContext context) {
    if (!_shouldShowPanel) return const SizedBox.shrink();
    final suggestions = _filteredSlashCommands;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
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
                    final text = inputController.text;
                    final firstSpace = text.indexOf(' ');
                    final arguments =
                        firstSpace == -1 ? '' : text.substring(firstSpace + 1);

                    final bool needsSpaceSuffix = command.command == '/tools' ||
                        command.command == '/plan';
                    final canonicalCmd = needsSpaceSuffix
                        ? '${command.command} '
                        : command.command;

                    final nextText = '$canonicalCmd$arguments';
                    inputController.text = nextText;

                    final nextCursorOffset = arguments.isEmpty
                        ? nextText.length
                        : canonicalCmd.length;

                    inputController.selection =
                        TextSelection.collapsed(offset: nextCursorOffset);
                    onStateChanged();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class LlmChatCommandsHelper {
  static const int maxToolSelectorHeightPercent = 78;

  static Future<List<ToolOption>?> loadAvailableTools(
    BuildContext context,
    AiStrings strings,
  ) async {
    try {
      final viewModel = context.read<AiChatViewModel>();
      final definitions = await viewModel.loadToolDefinitions();
      final tools = <ToolOption>[];
      for (final definition in definitions) {
        final name = toolNameFromDefinition(definition);
        if (name == null) continue;
        final function = definition['function'];
        final description =
            function is Map<String, dynamic> ? function['description'] : null;
        tools.add(
          ToolOption(
            name: name,
            description: description is String ? description : '',
          ),
        );
      }
      tools.sort((a, b) => a.name.compareTo(b.name));
      return tools;
    } catch (error) {
      if (context.mounted) {
        showCommandFeedback(context, strings.commandToolsLoadFailed);
      }
      return null;
    }
  }

  static Future<Set<String>?> openToolsSelector({
    required BuildContext context,
    required AiStrings strings,
    required List<ToolOption> availableTools,
    required Set<String> initialTools,
  }) async {
    if (availableTools.isEmpty) {
      showCommandFeedback(context, strings.commandToolsNoTools);
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
                  height: MediaQuery.sizeOf(sheetContext).height *
                      (maxToolSelectorHeightPercent / 100),
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

  static void showCommandFeedback(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  static Future<bool> setPlanModeFromUi({
    required BuildContext context,
    required AiChatRecord chat,
    required bool enabled,
    required AiStrings strings,
    bool showFeedback = true,
  }) async {
    if (!enabled && !canExitPlanMode(chat, actor: PlanModeExitActor.userUi)) {
      if (showFeedback) {
        showCommandFeedback(
          context,
          strings.language == AppLanguage.en
              ? 'Cannot exit Plan Mode until the latest assistant plan has persisted executable TODO steps.'
              : '最新一条助手计划还没有持久化可执行 TODO 步骤，暂时不能退出规划模式。',
        );
      }
      return false;
    }

    final viewModel = context.read<AiChatViewModel>();
    final updatedChat = chat.copyWith(
      planMode: enabled,
      updatedAt: DateTime.now(),
      clearApprovedPlan: enabled,
    );
    await viewModel.updateActiveChat(updatedChat);

    if (showFeedback && context.mounted) {
      final msg = strings.language == AppLanguage.en
          ? (enabled ? 'Plan Mode Enabled' : 'Plan Mode Disabled')
          : (enabled ? '规划模式已启用' : '规划模式已关闭');
      showCommandFeedback(context, msg);
    }
    return true;
  }

  static String? toolNameFromDefinition(Map<String, dynamic> definition) {
    final function = definition['function'];
    if (function is! Map) return null;
    final name = function['name'];
    return name is String ? name : null;
  }
}
