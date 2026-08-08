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

List<ToolOption> _normalizedToolOptions(Iterable<ToolOption> tools) {
  final byName = <String, ToolOption>{};
  for (final tool in tools) {
    final name = tool.name.trim();
    if (name.isEmpty) continue;
    final key = name.toLowerCase();
    final description = tool.description.trim();
    final existing = byName[key];
    if (existing == null) {
      byName[key] = ToolOption(name: name, description: description);
    } else if (existing.description.isEmpty && description.isNotEmpty) {
      byName[key] = ToolOption(name: existing.name, description: description);
    }
  }
  final result = byName.values.toList(growable: false);
  result.sort((a, b) {
    final insensitive = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return insensitive != 0 ? insensitive : a.name.compareTo(b.name);
  });
  return result;
}

Set<String> _normalizedToolSelection(
  Iterable<ToolOption> tools,
  Iterable<String> initialTools,
) {
  final canonicalByName = {
    for (final tool in tools) tool.name.toLowerCase(): tool.name,
  };
  final selected = <String>{};
  for (final initial in initialTools) {
    final name = canonicalByName[initial.trim().toLowerCase()];
    if (name != null) selected.add(name);
  }
  return selected;
}

class ToolSelectorSheet extends StatefulWidget {
  final AiStrings strings;
  final List<ToolOption> availableTools;
  final Set<String> initialTools;

  const ToolSelectorSheet({
    super.key,
    required this.strings,
    required this.availableTools,
    required this.initialTools,
  });

  @override
  State<ToolSelectorSheet> createState() => _ToolSelectorSheetState();
}

class _ToolSelectorSheetState extends State<ToolSelectorSheet> {
  late final TextEditingController _searchController;
  late final List<ToolOption> _tools;
  late final Set<String> _selected;
  bool _closing = false;

  List<ToolOption> get _filteredTools {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _tools;
    return _tools
        .where(
          (tool) =>
              tool.name.toLowerCase().contains(query) ||
              tool.description.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _tools = _normalizedToolOptions(widget.availableTools);
    _selected = _normalizedToolSelection(_tools, widget.initialTools);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _close([Set<String>? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(result == null ? null : Set<String>.from(result));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final filteredTools = _filteredTools;
    final media = MediaQuery.of(context);
    final compact = media.size.height - media.viewInsets.bottom < 300;

    return Material(
      color: colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 8 : 12,
            compact ? 4 : 8,
            compact ? 8 : 12,
            compact ? 4 : 12,
          ),
          child: Column(
            children: [
              if (!compact) ...[
                Container(
                  width: 34,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Row(
                children: [
                  Expanded(
                    child: compact
                        ? Row(
                            children: [
                              Expanded(
                                child: _ToolSelectorTitle(
                                  strings: widget.strings,
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _ToolSelectorCount(
                                strings: widget.strings,
                                count: _selected.length,
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ToolSelectorTitle(
                                strings: widget.strings,
                                style: theme.textTheme.titleLarge,
                              ),
                              _ToolSelectorCount(
                                strings: widget.strings,
                                count: _selected.length,
                              ),
                            ],
                          ),
                  ),
                  if (!compact) _buildClearSelectionButton(),
                ],
              ),
              SizedBox(height: compact ? 2 : 6),
              SizedBox(
                height: 48,
                child: TextField(
                  key: const ValueKey('tool-selector-search'),
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.strings.commandToolsSearch,
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            key: const ValueKey('tool-selector-clear-search'),
                            constraints: const BoxConstraints.tightFor(
                              width: 48,
                              height: 48,
                            ),
                            tooltip: widget.strings.commandToolsClearSearch,
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(height: compact ? 2 : 6),
              Expanded(
                child: filteredTools.isEmpty
                    ? Center(
                        child: Text(
                          widget.strings.commandToolsNoResult,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('tool-selector-list'),
                        itemCount: filteredTools.length,
                        itemBuilder: (context, index) {
                          final tool = filteredTools[index];
                          final isSelected = _selected.contains(tool.name);
                          return Semantics(
                            key: ValueKey(
                              'tool-option-${tool.name.toLowerCase()}',
                            ),
                            container: true,
                            label: tool.description.isEmpty
                                ? tool.name
                                : '${tool.name}, ${tool.description}',
                            checked: isSelected,
                            onTap: () =>
                                _setToolSelected(tool, selected: !isSelected),
                            child: ExcludeSemantics(
                              child: CheckboxListTile(
                                value: isSelected,
                                visualDensity: VisualDensity.standard,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  tool.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: compact || tool.description.isEmpty
                                    ? null
                                    : Text(
                                        tool.description,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                onChanged: (value) => _setToolSelected(
                                  tool,
                                  selected: value == true,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              SizedBox(height: compact ? 2 : 4),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (compact) _buildClearSelectionButton(),
                  TextButton(
                    key: const ValueKey('tool-selector-cancel'),
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: _closing ? null : _close,
                    child: Text(widget.strings.cancel),
                  ),
                  FilledButton(
                    key: const ValueKey('tool-selector-save'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: _closing ? null : () => _close(_selected),
                    child: Text(widget.strings.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClearSelectionButton() {
    return IconButton(
      key: const ValueKey('tool-selector-clear-selection'),
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      tooltip: widget.strings.commandToolsClearSelection,
      onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
      icon: const Icon(Icons.deselect_rounded),
    );
  }

  void _setToolSelected(ToolOption tool, {required bool selected}) {
    setState(() {
      if (selected) {
        _selected.add(tool.name);
      } else {
        _selected.remove(tool.name);
      }
    });
  }
}

class _ToolSelectorTitle extends StatelessWidget {
  final AiStrings strings;
  final TextStyle? style;

  const _ToolSelectorTitle({required this.strings, required this.style});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        strings.commandToolsTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}

class _ToolSelectorCount extends StatelessWidget {
  final AiStrings strings;
  final int count;

  const _ToolSelectorCount({required this.strings, required this.count});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Text(
        strings.commandToolsSelected(count),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
      return _normalizedToolOptions(tools);
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
    final tools = _normalizedToolOptions(availableTools);
    if (tools.isEmpty) {
      showCommandFeedback(context, strings.commandToolsNoTools);
      return null;
    }
    return showModalBottomSheet<Set<String>?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);
        final visibleHeight = (media.size.height - media.viewInsets.bottom)
            .clamp(0.0, media.size.height)
            .toDouble();
        final preferredHeight =
            media.size.height * (maxToolSelectorHeightPercent / 100);
        final sheetHeight = preferredHeight < visibleHeight
            ? preferredHeight
            : visibleHeight;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: SizedBox(
                width: double.infinity,
                height: sheetHeight,
                child: ToolSelectorSheet(
                  strings: strings,
                  availableTools: tools,
                  initialTools: initialTools,
                ),
              ),
            ),
          ),
        );
      },
    );
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
    final viewModel = context.read<AiChatViewModel>();
    final result = await viewModel.setPlanModeForActiveChat(
      chatId: chat.id,
      enabled: enabled,
    );
    final succeeded =
        result == SetPlanModeResult.updated ||
        result == SetPlanModeResult.unchanged;
    if (!showFeedback || !context.mounted) return succeeded;

    switch (result) {
      case SetPlanModeResult.updated:
        showCommandFeedback(context, strings.planModeUpdated(enabled));
      case SetPlanModeResult.unchanged:
        break;
      case SetPlanModeResult.busy:
        showCommandFeedback(context, strings.aiActionInProgress);
      case SetPlanModeResult.targetChanged:
        showCommandFeedback(context, strings.planModeTargetChanged);
      case SetPlanModeResult.failed:
        showCommandFeedback(context, strings.planModeUpdateFailed);
    }
    return succeeded;
  }

  static String? toolNameFromDefinition(Map<String, dynamic> definition) {
    final function = definition['function'];
    if (function is! Map) return null;
    final name = function['name'];
    return name is String ? name : null;
  }
}
