import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_settings.dart';
import '../../services/shortcut_command_service.dart';
import '../../services/ssh_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/responsive.dart';

class TerminalShortcutPanel extends StatelessWidget {
  final String sessionId;
  final TerminalStrings strings;
  final Color toolbarColor;
  final bool advancedKeyboardVisible;
  final TextEditingController complexInputController;
  final FocusNode terminalFocusNode;
  final bool ctrlActive;
  final VoidCallback onToggleCtrl;
  final bool altActive;
  final VoidCallback onToggleAlt;
  final VoidCallback onToggleAdvancedKeyboard;

  const TerminalShortcutPanel({
    super.key,
    required this.sessionId,
    required this.strings,
    required this.toolbarColor,
    required this.advancedKeyboardVisible,
    required this.complexInputController,
    required this.terminalFocusNode,
    required this.ctrlActive,
    required this.onToggleCtrl,
    required this.altActive,
    required this.onToggleAlt,
    required this.onToggleAdvancedKeyboard,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = colorScheme.outlineVariant;
    final scale = mobileUiScaleOf(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: toolbarColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          8 * scale,
          5 * scale,
          8 * scale,
          7 * scale,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: _buildShortcutBar(context, scale)),
                SizedBox(width: 4 * scale),
                _toolbarIconButton(
                  context,
                  scale: scale,
                  icon: Icons.add_circle_outline,
                  tooltip: strings.addShortcut,
                  onPressed: () => _showAddShortcutDialog(context),
                ),
                SizedBox(width: 4 * scale),
                _toolbarIconButton(
                  context,
                  scale: scale,
                  icon: advancedKeyboardVisible
                      ? Icons.keyboard_hide
                      : Icons.keyboard_command_key,
                  tooltip: strings.complexKeyboard,
                  onPressed: onToggleAdvancedKeyboard,
                ),
              ],
            ),
            if (advancedKeyboardVisible) _buildAdvancedKeyboard(context, scale),
          ],
        ),
      ),
    );
  }

  Widget _toolbarIconButton(
    BuildContext context, {
    required double scale,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 34 * scale,
      height: 34 * scale,
      child: IconButton(
        icon: Icon(icon, size: 20 * scale),
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

  Widget _buildShortcutBar(BuildContext context, double scale) {
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

    return Row(
      children: [
        _buildCtrlKey(context, scale),
        SizedBox(width: 2 * scale),
        _buildAltKey(context, scale),
        SizedBox(width: 4 * scale),
        Expanded(
          child: SizedBox(
            height: 36 * scale,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: commands.length,
              onReorder: (oldIndex, newIndex) {
                final reordered = commands.toList();
                final item = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, item);
                shortcuts.reorderCommands(
                  reordered.map((command) => command.id).toList(),
                );
              },
              itemBuilder: (context, index) {
                final command = commands[index];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(command.id),
                  index: index,
                  child: _quickKey(context, command, scale),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCtrlKey(BuildContext context, double scale) {
    final colorScheme = Theme.of(context).colorScheme;

    final activeBackground = colorScheme.primary;
    final activeBorder = colorScheme.primary;
    final activeForeground = colorScheme.onPrimary;

    final normalBackground =
        colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final normalBorder = colorScheme.outlineVariant;
    final normalForeground = colorScheme.onSurfaceVariant;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: InputChip(
        label: Text(
          'CTRL',
          style: TextStyle(
            fontSize: (11 * scale).clamp(9.5, 12.0),
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
          ),
        ),
        labelStyle: TextStyle(
          color: ctrlActive ? activeForeground : normalForeground,
        ),
        backgroundColor: ctrlActive ? activeBackground : normalBackground,
        side: BorderSide(
          color: ctrlActive ? activeBorder : normalBorder,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: (7 * scale).clamp(4.0, 8.0),
          vertical: (3 * scale).clamp(1.5, 4.0),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: onToggleCtrl,
      ),
    );
  }

  Widget _buildAltKey(BuildContext context, double scale) {
    final colorScheme = Theme.of(context).colorScheme;

    final activeBackground = colorScheme.primary;
    final activeBorder = colorScheme.primary;
    final activeForeground = colorScheme.onPrimary;

    final normalBackground =
        colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final normalBorder = colorScheme.outlineVariant;
    final normalForeground = colorScheme.onSurfaceVariant;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: InputChip(
        label: Text(
          'ALT',
          style: TextStyle(
            fontSize: (11 * scale).clamp(9.5, 12.0),
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
          ),
        ),
        labelStyle: TextStyle(
          color: altActive ? activeForeground : normalForeground,
        ),
        backgroundColor: altActive ? activeBackground : normalBackground,
        side: BorderSide(
          color: altActive ? activeBorder : normalBorder,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: (7 * scale).clamp(4.0, 8.0),
          vertical: (3 * scale).clamp(1.5, 4.0),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: onToggleAlt,
      ),
    );
  }

  Widget _buildAdvancedKeyboard(BuildContext context, double scale) {
    return Padding(
      padding: EdgeInsets.only(top: 6 * scale),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _keyGroup(
              context,
              [
                const _KeySpec('INS', '\x1b[2~'),
                const _KeySpec('DEL', '\x1b[3~'),
                const _KeySpec('SPACE', ' '),
                const _KeySpec('CTRL+A', '\x01'),
                const _KeySpec('CTRL+E', '\x05'),
                const _KeySpec('CTRL+U', '\x15'),
                const _KeySpec('CTRL+K', '\x0b'),
                const _KeySpec('CTRL+W', '\x17'),
                const _KeySpec('CTRL+R', '\x12'),
                const _KeySpec('CTRL+Z', '\x1a'),
                const _KeySpec('CTRL+\\', '\x1c'),
              ],
              scale),
          SizedBox(height: 4 * scale),
          _keyGroup(
              context,
              [
                const _KeySpec('ALT+B', '\x1bb'),
                const _KeySpec('ALT+F', '\x1bf'),
                const _KeySpec('ALT+D', '\x1bd'),
                const _KeySpec('F1', '\x1bOP'),
                const _KeySpec('F2', '\x1bOQ'),
                const _KeySpec('F3', '\x1bOR'),
                const _KeySpec('F4', '\x1bOS'),
                const _KeySpec('F5', '\x1b[15~'),
                const _KeySpec('F6', '\x1b[17~'),
                const _KeySpec('F7', '\x1b[18~'),
                const _KeySpec('F8', '\x1b[19~'),
                const _KeySpec('F9', '\x1b[20~'),
                const _KeySpec('F10', '\x1b[21~'),
                const _KeySpec('F11', '\x1b[23~'),
                const _KeySpec('F12', '\x1b[24~'),
              ],
              scale),
          SizedBox(height: 6 * scale),
          SizedBox(
            height: 118 * scale,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: complexInputController,
                    decoration: InputDecoration(
                      hintText: strings.multilineHint,
                      alignLabelWithHint: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10 * scale,
                        vertical: 8 * scale,
                      ),
                    ),
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    minLines: null,
                    maxLines: null,
                    expands: true,
                  ),
                ),
                SizedBox(width: 6 * scale),
                SizedBox(
                  width: 44 * scale,
                  height: 44 * scale,
                  child: IconButton(
                    icon: Icon(Icons.send, size: 20 * scale),
                    tooltip: strings.send,
                    style: IconButton.styleFrom(
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.1),
                      foregroundColor: Theme.of(context).colorScheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
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

  Widget _keyGroup(BuildContext context, List<_KeySpec> keys, double scale) {
    final commands = keys
        .map(
          (key) =>
              ShortcutCommand(id: key.id, label: key.label, code: key.code),
        )
        .toList();

    return SizedBox(
      height: 34 * scale,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: commands.length,
        separatorBuilder: (_, __) => SizedBox(width: 4 * scale),
        itemBuilder: (context, index) {
          return _quickKey(context, commands[index], scale);
        },
      ),
    );
  }

  Widget _quickKey(
      BuildContext context, ShortcutCommand command, double scale) {
    final colorScheme = Theme.of(context).colorScheme;
    final normalBackground =
        colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final normalBorder = colorScheme.outlineVariant;
    final customBackground = colorScheme.primary.withValues(alpha: 0.12);
    final customBorder =
        command.custom ? AppTheme.terminalCyan : colorScheme.primary;
    final foreground = colorScheme.onSurfaceVariant;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: InputChip(
        label: Text(
          command.label,
          style: TextStyle(
            fontSize: (11 * scale).clamp(9.5, 12.0),
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            color: command.custom ? customBorder : foreground,
          ),
        ),
        backgroundColor: command.custom ? customBackground : normalBackground,
        side: BorderSide(
          color: command.custom ? customBorder : normalBorder,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: (7 * scale).clamp(4.0, 8.0),
          vertical: (3 * scale).clamp(1.5, 4.0),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: command.custom
            ? Icon(Icons.bolt, size: 14 * scale, color: customBorder)
            : null,
        deleteIcon: Icon(Icons.close_rounded, size: 14 * scale),
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
        content: SingleChildScrollView(
          child: Column(
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
