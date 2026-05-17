import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_settings.dart';
import '../../services/shortcut_command_service.dart';
import '../../services/ssh_service.dart';
import '../../theme/app_theme.dart';

class TerminalShortcutPanel extends StatelessWidget {
  final String sessionId;
  final TerminalStrings strings;
  final Color toolbarColor;
  final bool advancedKeyboardVisible;
  final TextEditingController complexInputController;
  final FocusNode terminalFocusNode;
  final VoidCallback onToggleAdvancedKeyboard;

  const TerminalShortcutPanel({
    super.key,
    required this.sessionId,
    required this.strings,
    required this.toolbarColor,
    required this.advancedKeyboardVisible,
    required this.complexInputController,
    required this.terminalFocusNode,
    required this.onToggleAdvancedKeyboard,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor =
        isDark ? const Color(0xFF30363D) : const Color(0xFFD0D7DE);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: toolbarColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: _buildShortcutBar(context)),
                const SizedBox(width: 4),
                _toolbarIconButton(
                  context,
                  icon: Icons.add_circle_outline,
                  tooltip: strings.addShortcut,
                  onPressed: () => _showAddShortcutDialog(context),
                ),
                const SizedBox(width: 4),
                _toolbarIconButton(
                  context,
                  icon: advancedKeyboardVisible
                      ? Icons.keyboard_hide
                      : Icons.keyboard_command_key,
                  tooltip: strings.complexKeyboard,
                  onPressed: onToggleAdvancedKeyboard,
                ),
              ],
            ),
            if (advancedKeyboardVisible) _buildAdvancedKeyboard(context),
          ],
        ),
      ),
    );
  }

  Widget _toolbarIconButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor:
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          foregroundColor: Theme.of(context).colorScheme.primary,
        ),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildShortcutBar(BuildContext context) {
    final shortcuts = context.read<ShortcutCommandService>();
    context.select<ShortcutCommandService, int>(
      (service) => service.orderVersion,
    );
    final customCommands =
        context.select<ShortcutCommandService, List<ShortcutCommand>>(
            (service) => service.customCommands);
    final commands = shortcuts.sortByUsage([
      const ShortcutCommand(id: 'tab', label: 'TAB', code: '\t'),
      const ShortcutCommand(id: 'esc', label: 'ESC', code: '\x1b'),
      const ShortcutCommand(id: 'enter', label: 'ENTER', code: '\r'),
      const ShortcutCommand(id: 'bksp', label: 'BKSP', code: '\x7f'),
      const ShortcutCommand(id: 'up', label: '↑', code: '\x1b[A'),
      const ShortcutCommand(id: 'down', label: '↓', code: '\x1b[B'),
      const ShortcutCommand(id: 'left', label: '←', code: '\x1b[D'),
      const ShortcutCommand(id: 'right', label: '→', code: '\x1b[C'),
      const ShortcutCommand(id: 'home', label: 'HOME', code: '\x1b[H'),
      const ShortcutCommand(id: 'end', label: 'END', code: '\x1b[F'),
      const ShortcutCommand(id: 'pgup', label: 'PGUP', code: '\x1b[5~'),
      const ShortcutCommand(id: 'pgdn', label: 'PGDN', code: '\x1b[6~'),
      const ShortcutCommand(id: 'ctrl_c', label: 'CTRL+C', code: '\x03'),
      const ShortcutCommand(id: 'ctrl_d', label: 'CTRL+D', code: '\x04'),
      const ShortcutCommand(id: 'ctrl_l', label: 'CTRL+L', code: '\x0c'),
      ...customCommands,
    ]);

    return SizedBox(
      height: 36,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        itemCount: commands.length,
        onReorder: (oldIndex, newIndex) {
          final reordered = commands.toList();
          final item = reordered.removeAt(oldIndex);
          final targetIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
          reordered.insert(targetIndex, item);
          shortcuts.reorderCommands(
            reordered.map((command) => command.id).toList(),
          );
        },
        itemBuilder: (context, index) {
          final command = commands[index];
          return ReorderableDelayedDragStartListener(
            key: ValueKey(command.id),
            index: index,
            child: _quickKey(context, command),
          );
        },
      ),
    );
  }

  Widget _buildAdvancedKeyboard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _keyGroup(context, [
            _KeySpec('INS', '\x1b[2~'),
            _KeySpec('DEL', '\x1b[3~'),
            _KeySpec('SPACE', ' '),
            _KeySpec('CTRL+A', '\x01'),
            _KeySpec('CTRL+E', '\x05'),
            _KeySpec('CTRL+U', '\x15'),
            _KeySpec('CTRL+K', '\x0b'),
            _KeySpec('CTRL+W', '\x17'),
            _KeySpec('CTRL+R', '\x12'),
            _KeySpec('CTRL+Z', '\x1a'),
            _KeySpec('CTRL+\\', '\x1c'),
          ]),
          const SizedBox(height: 4),
          _keyGroup(context, [
            _KeySpec('ALT+B', '\x1bb'),
            _KeySpec('ALT+F', '\x1bf'),
            _KeySpec('ALT+D', '\x1bd'),
            _KeySpec('F1', '\x1bOP'),
            _KeySpec('F2', '\x1bOQ'),
            _KeySpec('F3', '\x1bOR'),
            _KeySpec('F4', '\x1bOS'),
            _KeySpec('F5', '\x1b[15~'),
            _KeySpec('F6', '\x1b[17~'),
            _KeySpec('F7', '\x1b[18~'),
            _KeySpec('F8', '\x1b[19~'),
            _KeySpec('F9', '\x1b[20~'),
            _KeySpec('F10', '\x1b[21~'),
            _KeySpec('F11', '\x1b[23~'),
            _KeySpec('F12', '\x1b[24~'),
          ]),
          const SizedBox(height: 6),
          SizedBox(
            height: 118,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: complexInputController,
                    decoration: InputDecoration(
                      hintText: strings.multilineHint,
                      alignLabelWithHint: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    minLines: null,
                    maxLines: null,
                    expands: true,
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 44,
                  child: IconButton(
                    icon: const Icon(Icons.send, size: 20),
                    tooltip: strings.send,
                    onPressed: () => _sendComplexInput(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyGroup(BuildContext context, List<_KeySpec> keys) {
    final commands = keys
        .map(
          (key) =>
              ShortcutCommand(id: key.id, label: key.label, code: key.code),
        )
        .toList();

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: commands.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          return _quickKey(context, commands[index]);
        },
      ),
    );
  }

  Widget _quickKey(BuildContext context, ShortcutCommand command) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normalBackground =
        isDark ? const Color(0xFF21262D) : const Color(0xFFF6F8FA);
    final normalBorder =
        isDark ? const Color(0xFF30363D) : const Color(0xFFD0D7DE);
    final customBackground = Theme.of(context)
        .colorScheme
        .primary
        .withValues(alpha: isDark ? 0.32 : 0.12);
    final customBorder = command.custom
        ? AppTheme.terminalCyan
        : Theme.of(context).colorScheme.primary;
    final foreground = isDark
        ? const Color(0xFFC9D1D9)
        : Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InputChip(
        label: Text(
          command.label,
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            color: command.custom ? customBorder : foreground,
          ),
        ),
        backgroundColor: command.custom ? customBackground : normalBackground,
        side: BorderSide(
          color: command.custom ? customBorder : normalBorder,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: command.custom
            ? Icon(Icons.bolt, size: 14, color: customBorder)
            : null,
        deleteIcon: const Icon(Icons.close_rounded, size: 14),
        onDeleted: command.custom
            ? () => _confirmRemoveShortcut(context, command)
            : null,
        onPressed: () {
          context.read<ShortcutCommandService>().recordUse(command.id);
          context.read<SshService>().sendData(sessionId, command.code);
          terminalFocusNode.requestFocus();
        },
      ),
    );
  }

  Future<void> _showAddShortcutDialog(BuildContext context) async {
    var label = '';
    var command = '';

    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.addShortcut),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: InputDecoration(
                labelText: strings.label,
                hintText: 'e.g. LS',
              ),
              textInputAction: TextInputAction.next,
              onChanged: (value) => label = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: strings.command,
                hintText: 'e.g. ls -la',
                alignLabelWithHint: true,
              ),
              keyboardType: TextInputType.multiline,
              minLines: 2,
              maxLines: 4,
              onChanged: (value) => command = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, (label, command)),
            child: Text(strings.add),
          ),
        ],
      ),
    );

    if (result == null || !context.mounted) return;

    await context
        .read<ShortcutCommandService>()
        .addCustomCommand(result.$1, result.$2);
  }

  Future<void> _confirmRemoveShortcut(
    BuildContext context,
    ShortcutCommand command,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.removeShortcut),
        content: Text(strings.removeShortcutContent(command.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.remove),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await context
        .read<ShortcutCommandService>()
        .removeCustomCommand(command.id);
  }

  void _sendComplexInput(BuildContext context) {
    final rawText = complexInputController.text;
    if (rawText.isEmpty) return;

    context.read<SshService>().sendData(sessionId, rawText);
    complexInputController.clear();
    terminalFocusNode.requestFocus();
  }
}

class _KeySpec {
  final String id;
  final String label;
  final String code;

  const _KeySpec(this.label, this.code) : id = 'adv_$label';
}
