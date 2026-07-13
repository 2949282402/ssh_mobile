// ignore_for_file: invalid_use_of_protected_member
part of '../llm_chat_screen.dart';

class SlashCommandMeta {
  final String command;
  final bool preservesArguments;

  const SlashCommandMeta({
    required this.command,
    this.preservesArguments = false,
  });
}

class ToolOption {
  final String name;
  final String description;

  const ToolOption({required this.name, required this.description});
}

const List<SlashCommandMeta> _defaultSlashCommands = [
  SlashCommandMeta(command: '/compact'),
  SlashCommandMeta(command: '/tools', preservesArguments: true),
  SlashCommandMeta(command: '/skills'),
  SlashCommandMeta(command: '/plan', preservesArguments: true),
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

    final firstWhitespace = text.indexOf(RegExp(r'\s'));
    if (firstWhitespace == -1) {
      return true;
    }

    final selection = inputController.selection;
    if (selection.isValid &&
        selection.isCollapsed &&
        selection.baseOffset <= firstWhitespace) {
      return true;
    }

    if (text == '/' || text.startsWith('/ ')) return true;

    return false;
  }

  List<SlashCommandMeta> get _filteredSlashCommands {
    final text = inputController.text;
    if (text.isEmpty || !text.startsWith('/')) return const [];

    final firstWhitespace = text.indexOf(RegExp(r'\s'));
    final query = firstWhitespace == -1
        ? text.substring(1).toLowerCase()
        : text.substring(1, firstWhitespace).toLowerCase();

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
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) => Divider(
            height: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
          itemBuilder: (context, index) {
            final command = suggestions[index];
            return ListTile(
              key: ValueKey('slash-command-${command.command.substring(1)}'),
              minTileHeight: 48,
              minVerticalPadding: 8,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Text(
                command.command,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                _commandSummary(command),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _selectCommand(command),
            );
          },
        ),
      ),
    );
  }

  String _commandSummary(SlashCommandMeta command) {
    switch (command.command) {
      case '/compact':
        return strings.commandCompactSummary;
      case '/tools':
        return strings.commandToolsSummary;
      case '/skills':
        return strings.commandSkillsSummary;
      case '/plan':
        return strings.commandPlanSummary;
      default:
        return command.command;
    }
  }

  void _selectCommand(SlashCommandMeta command) {
    final text = inputController.text;
    final firstWhitespace = text.indexOf(RegExp(r'\s'));
    final arguments = firstWhitespace == -1
        ? ''
        : text.substring(firstWhitespace).trimLeft();
    final nextText = command.preservesArguments
        ? (arguments.isEmpty
              ? '${command.command} '
              : '${command.command} $arguments')
        : command.command;

    inputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    onStateChanged();
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
        final description = function is Map<String, dynamic>
            ? function['description']
            : null;
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
                  height:
                      MediaQuery.sizeOf(sheetContext).height *
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
                                      color: Theme.of(
                                        sheetContext,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: filteredTools.length,
                                  itemBuilder: (ctx, index) {
                                    final tool = filteredTools[index];
                                    final isSelected = selected.contains(
                                      tool.name,
                                    );
                                    return CheckboxListTile(
                                      value: isSelected,
                                      title: Text(tool.name),
                                      subtitle: Text(tool.description),
                                      onChanged: (value) => setSheetState(() {
                                        if (!sheetContext.mounted) {
                                          return;
                                        }
                                        if (value == true) {
                                          selected.add(tool.name);
                                        } else {
                                          selected.remove(tool.name);
                                        }
                                      }),
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
                                Navigator.of(
                                  sheetContext,
                                ).pop(Set.from(selected));
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
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
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
