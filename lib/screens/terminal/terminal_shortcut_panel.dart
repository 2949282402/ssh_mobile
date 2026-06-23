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
        child: Row(
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
              icon: Icons.keyboard_command_key,
              tooltip: strings.complexKeyboard,
              onPressed: () => _showAdvancedKeyboardBottomSheet(context, scale),
            ),
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
      width: 36 * scale,
      height: 36 * scale,
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

    // 过滤出核心最常用快捷键
    final commands = shortcuts.sortByUsage([
      const ShortcutCommand(id: 'tab', label: 'TAB', code: '\t'),
      const ShortcutCommand(id: 'esc', label: 'ESC', code: '\x1b'),
      const ShortcutCommand(id: 'enter', label: 'ENTER', code: '\r'),
      const ShortcutCommand(id: 'bksp', label: 'BKSP', code: '\x7f'),
      const ShortcutCommand(id: 'up', label: '↑', code: '\x1b[A'),
      const ShortcutCommand(id: 'down', label: '↓', code: '\x1b[B'),
      const ShortcutCommand(id: 'left', label: '←', code: '\x1b[D'),
      const ShortcutCommand(id: 'right', label: '→', code: '\x1b[C'),
      const ShortcutCommand(id: 'ctrl_c', label: 'CTRL+C', code: '\x03'),
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
              onReorderItem: (oldIndex, newIndex) {
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

    // 默认态采用带主题色边框的浅色卡片，与普通即时发送的 key 做明显区分
    final normalBackground = colorScheme.primary.withValues(alpha: 0.08);
    final normalBorder = colorScheme.primary.withValues(alpha: 0.35);
    final normalForeground = colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: InputChip(
        label: Text(
          'CTRL',
          style: TextStyle(
            fontSize: (11 * scale).clamp(9.5, 12.0),
            fontFamily: 'monospace',
            fontFamilyFallback: const [
              'Consolas',
              'Microsoft YaHei',
              'PingFang SC',
              'sans-serif'
            ],
            fontWeight: FontWeight.w700,
          ),
        ),
        labelStyle: TextStyle(
          color: ctrlActive ? activeForeground : normalForeground,
        ),
        backgroundColor: ctrlActive ? activeBackground : normalBackground,
        side: BorderSide(
          color: ctrlActive ? activeBorder : normalBorder,
          width: 1.2,
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

    final normalBackground = colorScheme.primary.withValues(alpha: 0.08);
    final normalBorder = colorScheme.primary.withValues(alpha: 0.35);
    final normalForeground = colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: InputChip(
        label: Text(
          'ALT',
          style: TextStyle(
            fontSize: (11 * scale).clamp(9.5, 12.0),
            fontFamily: 'monospace',
            fontFamilyFallback: const [
              'Consolas',
              'Microsoft YaHei',
              'PingFang SC',
              'sans-serif'
            ],
            fontWeight: FontWeight.w700,
          ),
        ),
        labelStyle: TextStyle(
          color: altActive ? activeForeground : normalForeground,
        ),
        backgroundColor: altActive ? activeBackground : normalBackground,
        side: BorderSide(
          color: altActive ? activeBorder : normalBorder,
          width: 1.2,
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
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 120 * scale),
        child: InputChip(
          label: Text(
            command.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: (11 * scale).clamp(9.5, 12.0),
              fontFamily: 'monospace',
              fontFamilyFallback: const [
                'Consolas',
                'Microsoft YaHei',
                'PingFang SC',
                'sans-serif'
              ],
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
      ),
    );
  }

  void _showAdvancedKeyboardBottomSheet(BuildContext context, double scale) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final localColorScheme = Theme.of(context).colorScheme;
        return Container(
          decoration: BoxDecoration(
            color: localColorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16 * scale,
            left: 16 * scale,
            right: 16 * scale,
            top: 16 * scale,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      strings.complexKeyboard,
                      style: TextStyle(
                        fontSize: 16 * scale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Text input row
                SizedBox(
                  height: 48 * scale,
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
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 48 * scale,
                        child: IconButton(
                          icon: const Icon(Icons.send),
                          tooltip: strings.send,
                          style: IconButton.styleFrom(
                            backgroundColor:
                                localColorScheme.primary.withValues(alpha: 0.1),
                            foregroundColor: localColorScheme.primary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: () {
                            _sendComplexInput(context);
                            Navigator.pop(ctx);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Group 1: Navigation & Shell (HOME, END, PGUP, PGDN, CTRL+D, CTRL+L)
                Text(
                  'Navigation & Shell',
                  style: TextStyle(
                    fontSize: 12 * scale,
                    fontWeight: FontWeight.w600,
                    color: localColorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6 * scale,
                  runSpacing: 6 * scale,
                  children: [
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'home', label: 'HOME', code: '\x1b[H'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'end', label: 'END', code: '\x1b[F'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'pgup', label: 'PGUP', code: '\x1b[5~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'pgdn', label: 'PGDN', code: '\x1b[6~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_d', label: 'CTRL+D', code: '\x04'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_l', label: 'CTRL+L', code: '\x0c'),
                        scale),
                  ],
                ),
                const SizedBox(height: 16),
                // Group 2: Edit & Control (INS, DEL, SPACE, CTRL shortcuts)
                Text(
                  'Edit & Control',
                  style: TextStyle(
                    fontSize: 12 * scale,
                    fontWeight: FontWeight.w600,
                    color: localColorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6 * scale,
                  runSpacing: 6 * scale,
                  children: [
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ins', label: 'INS', code: '\x1b[2~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'del', label: 'DEL', code: '\x1b[3~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'space', label: 'SPACE', code: ' '),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_a', label: 'CTRL+A', code: '\x01'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_e', label: 'CTRL+E', code: '\x05'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_u', label: 'CTRL+U', code: '\x15'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_k', label: 'CTRL+K', code: '\x0b'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_w', label: 'CTRL+W', code: '\x17'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_r', label: 'CTRL+R', code: '\x12'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_z', label: 'CTRL+Z', code: '\x1a'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'ctrl_backslash',
                            label: 'CTRL+\\',
                            code: '\x1c'),
                        scale),
                  ],
                ),
                const SizedBox(height: 16),
                // Group 3: F1-F12 keys
                Text(
                  'Function Keys',
                  style: TextStyle(
                    fontSize: 12 * scale,
                    fontWeight: FontWeight.w600,
                    color: localColorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6 * scale,
                  runSpacing: 6 * scale,
                  children: [
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f1', label: 'F1', code: '\x1bOP'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f2', label: 'F2', code: '\x1bOQ'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f3', label: 'F3', code: '\x1bOR'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f4', label: 'F4', code: '\x1bOS'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f5', label: 'F5', code: '\x1b[15~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f6', label: 'F6', code: '\x1b[17~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f7', label: 'F7', code: '\x1b[18~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f8', label: 'F8', code: '\x1b[19~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f9', label: 'F9', code: '\x1b[20~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f10', label: 'F10', code: '\x1b[21~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f11', label: 'F11', code: '\x1b[23~'),
                        scale),
                    _sheetKey(
                        context,
                        const ShortcutCommand(
                            id: 'f12', label: 'F12', code: '\x1b[24~'),
                        scale),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sheetKey(
      BuildContext context, ShortcutCommand command, double scale) {
    final colorScheme = Theme.of(context).colorScheme;
    final normalBackground =
        colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final normalBorder = colorScheme.outlineVariant;
    final foreground = colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          context.read<ShortcutCommandService>().recordUse(command.id);
          context.read<SshService>().sendData(sessionId, command.code);
          terminalFocusNode.requestFocus();
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding:
              EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
          decoration: BoxDecoration(
            color: normalBackground,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: normalBorder),
          ),
          child: Text(
            command.label,
            style: TextStyle(
              fontSize: (11 * scale).clamp(9.5, 12.0),
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ),
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
