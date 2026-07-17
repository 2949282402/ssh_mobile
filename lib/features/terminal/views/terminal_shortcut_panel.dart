import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/shortcut_command_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/utils/responsive.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';

class TerminalShortcutPanel extends StatelessWidget {
  final String sessionId;
  final TerminalStrings strings;
  final Color toolbarColor;
  final TextEditingController complexInputController;
  final FocusNode terminalFocusNode;
  final bool ctrlActive;
  final VoidCallback onToggleCtrl;
  final bool altActive;
  final VoidCallback onToggleAlt;

  const TerminalShortcutPanel({
    super.key,
    required this.sessionId,
    required this.strings,
    required this.toolbarColor,
    required this.complexInputController,
    required this.terminalFocusNode,
    required this.ctrlActive,
    required this.onToggleCtrl,
    required this.altActive,
    required this.onToggleAlt,
  });

  @visibleForTesting
  static int adjustedReorderIndex(int oldIndex, int newIndex) {
    return newIndex > oldIndex ? newIndex - 1 : newIndex;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = colorScheme.outlineVariant;
    final scale = mobileUiScaleOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelColor = Color.alphaBlend(
      colorScheme.surface.withValues(alpha: isDark ? 0.72 : 0.82),
      toolbarColor,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: panelColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final accessibleCompactLayout =
                constraints.maxWidth < 400 &&
                MediaQuery.textScalerOf(context).scale(1) > 1.3;
            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _toolbarIconButton(
                  context,
                  key: const ValueKey('terminal-add-shortcut'),
                  icon: Icons.add_rounded,
                  tooltip: strings.addShortcut,
                  onPressed: () => _showAddShortcutDialog(context),
                ),
                const SizedBox(width: 6),
                _toolbarIconButton(
                  context,
                  key: const ValueKey('terminal-advanced-keyboard'),
                  icon: Icons.keyboard_rounded,
                  tooltip: strings.windowsKeyboard,
                  onPressed: () =>
                      _showAdvancedKeyboardBottomSheet(context, scale),
                ),
              ],
            );

            if (accessibleCompactLayout) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildShortcutBar(context, scale, scrollAll: true),
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: _buildShortcutBar(context, scale)),
                const SizedBox(width: 6),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _toolbarIconButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      key: key,
      width: 48,
      height: 48,
      child: IconButton(
        icon: Icon(icon, size: 21),
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.11),
          foregroundColor: Theme.of(context).colorScheme.primary,
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.18),
          ),
        ),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildShortcutBar(
    BuildContext context,
    double scale, {
    bool scrollAll = false,
  }) {
    final shortcuts = context.read<ShortcutCommandService>();
    context.select<ShortcutCommandService, int>(
      (service) => service.orderVersion,
    );
    final customCommands = context
        .select<ShortcutCommandService, List<ShortcutCommand>>(
          (service) => service.customCommands,
        );

    final allBuiltin = [
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
    ];

    final sortedAll = shortcuts.sortByUsage([...allBuiltin, ...customCommands]);

    final primaryIds = {
      'tab',
      'esc',
      'enter',
      'bksp',
      'up',
      'down',
      'left',
      'right',
      'ctrl_c',
    };
    final primaryCommands = sortedAll
        .where((c) => primaryIds.contains(c.id) || c.custom)
        .toList();
    final secondaryCommands = sortedAll
        .where((c) => !primaryIds.contains(c.id) && !c.custom)
        .toList();

    if (scrollAll) {
      return SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _buildCtrlKey(context, scale),
            SizedBox(width: 2 * scale),
            _buildAltKey(context, scale),
            SizedBox(width: 4 * scale),
            for (final command in primaryCommands)
              _quickKey(context, command, scale),
            if (secondaryCommands.isNotEmpty) ...[
              SizedBox(width: 4 * scale),
              _moreKeysButton(context, secondaryCommands, scale),
            ],
          ],
        ),
      );
    }

    return Row(
      children: [
        _buildCtrlKey(context, scale),
        SizedBox(width: 2 * scale),
        _buildAltKey(context, scale),
        SizedBox(width: 4 * scale),
        Expanded(
          child: SizedBox(
            height: 48,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: primaryCommands.length,
              onReorderItem: (oldIndex, newIndex) {
                final reordered = primaryCommands.toList();
                final item = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, item);
                // Also reconstruct full commands list order to keep customized list state
                final finalIds = [
                  ...reordered.map((c) => c.id),
                  ...secondaryCommands.map((c) => c.id),
                ];
                shortcuts.reorderCommands(finalIds);
              },
              itemBuilder: (context, index) {
                final command = primaryCommands[index];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(command.id),
                  index: index,
                  child: _quickKey(context, command, scale),
                );
              },
            ),
          ),
        ),
        if (secondaryCommands.isNotEmpty) ...[
          SizedBox(width: 4 * scale),
          _moreKeysButton(context, secondaryCommands, scale),
        ],
      ],
    );
  }

  Widget _moreKeysButton(
    BuildContext context,
    List<ShortcutCommand> secondaryCommands,
    double scale,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: InputChip(
        label: Text(
          strings.language == AppLanguage.en ? 'MORE' : '更多键',
          style: TextStyle(
            fontSize: (11 * scale).clamp(9.5, 12.0),
            fontWeight: FontWeight.w700,
            color: colorScheme.primary,
          ),
        ),
        backgroundColor: colorScheme.primary.withValues(alpha: 0.08),
        side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.35)),
        padding: EdgeInsets.symmetric(
          horizontal: (7 * scale).clamp(4.0, 8.0),
          vertical: (3 * scale).clamp(1.5, 4.0),
        ),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onPressed: () =>
            _showMoreKeysBottomSheet(context, secondaryCommands, scale),
      ),
    );
  }

  Widget _buildCtrlKey(BuildContext context, double scale) {
    final colorScheme = Theme.of(context).colorScheme;

    final activeBackground = colorScheme.primary;
    final activeBorder = colorScheme.primary;
    final activeForeground = colorScheme.onPrimary;

    final normalBackground = colorScheme.surfaceContainer.withValues(
      alpha: 0.72,
    );
    final normalBorder = colorScheme.primary.withValues(alpha: 0.48);
    final normalForeground = colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
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
                'sans-serif',
              ],
              fontWeight: FontWeight.w700,
            ),
          ),
          labelStyle: TextStyle(
            color: ctrlActive ? activeForeground : normalForeground,
          ),
          backgroundColor: ctrlActive ? activeBackground : normalBackground,
          side: BorderSide(color: ctrlActive ? activeBorder : normalBorder),
          padding: EdgeInsets.symmetric(
            horizontal: (7 * scale).clamp(4.0, 8.0),
            vertical: (3 * scale).clamp(1.5, 4.0),
          ),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onPressed: onToggleCtrl,
        ),
      ),
    );
  }

  Widget _buildAltKey(BuildContext context, double scale) {
    final colorScheme = Theme.of(context).colorScheme;

    final activeBackground = colorScheme.primary;
    final activeBorder = colorScheme.primary;
    final activeForeground = colorScheme.onPrimary;

    final normalBackground = colorScheme.surfaceContainer.withValues(
      alpha: 0.72,
    );
    final normalBorder = colorScheme.primary.withValues(alpha: 0.48);
    final normalForeground = colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
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
                'sans-serif',
              ],
              fontWeight: FontWeight.w700,
            ),
          ),
          labelStyle: TextStyle(
            color: altActive ? activeForeground : normalForeground,
          ),
          backgroundColor: altActive ? activeBackground : normalBackground,
          side: BorderSide(color: altActive ? activeBorder : normalBorder),
          padding: EdgeInsets.symmetric(
            horizontal: (7 * scale).clamp(4.0, 8.0),
            vertical: (3 * scale).clamp(1.5, 4.0),
          ),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onPressed: onToggleAlt,
        ),
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
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: commands.length,
        separatorBuilder: (_, _) => SizedBox(width: 4 * scale),
        itemBuilder: (context, index) {
          return _quickKey(context, commands[index], scale);
        },
      ),
    );
  }

  Widget _keyWrap(BuildContext context, List<_KeySpec> keys, double scale) {
    final commands = keys
        .map(
          (key) =>
              ShortcutCommand(id: key.id, label: key.label, code: key.code),
        )
        .toList();

    return Wrap(
      spacing: 4 * scale,
      runSpacing: 4 * scale,
      children: commands.map((cmd) => _quickKey(context, cmd, scale)).toList(),
    );
  }

  Widget _quickKey(
    BuildContext context,
    ShortcutCommand command,
    double scale,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final normalBackground = colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.5,
    );
    final normalBorder = colorScheme.outlineVariant;
    final customBackground = colorScheme.primary.withValues(alpha: 0.12);
    final customBorder = command.custom
        ? AppTheme.terminalCyan
        : colorScheme.primary;
    final foreground = colorScheme.onSurfaceVariant;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2 * scale),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: InputChip(
          label: Container(
            constraints: BoxConstraints(maxWidth: 80 * scale),
            child: Text(
              command.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: (11 * scale).clamp(9.5, 12.0),
                fontFamily: 'monospace',
                fontFamilyFallback: const [
                  'Consolas',
                  'Microsoft YaHei',
                  'PingFang SC',
                  'sans-serif',
                ],
                fontWeight: FontWeight.w700,
                color: command.custom ? customBorder : foreground,
              ),
            ),
          ),
          backgroundColor: command.custom ? customBackground : normalBackground,
          side: BorderSide(color: command.custom ? customBorder : normalBorder),
          padding: EdgeInsets.symmetric(
            horizontal: (7 * scale).clamp(4.0, 8.0),
            vertical: (3 * scale).clamp(1.5, 4.0),
          ),
          materialTapTargetSize: MaterialTapTargetSize.padded,
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

  void _showMoreKeysBottomSheet(
    BuildContext context,
    List<ShortcutCommand> secondaryCommands,
    double scale,
  ) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppPageHeader(
                  title: strings.moreKeys,
                  subtitle: strings.moreKeysHint,
                  icon: Icons.keyboard_alt_outlined,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: secondaryCommands.map((cmd) {
                    return ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: InputChip(
                        label: Text(
                          cmd.label,
                          style: TextStyle(
                            fontSize: (11 * scale).clamp(9.5, 12.0),
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onPressed: () {
                          context.read<ShortcutCommandService>().recordUse(
                            cmd.id,
                          );
                          context.read<SshService>().sendData(
                            sessionId,
                            cmd.code,
                          );
                          terminalFocusNode.requestFocus();
                        },
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAdvancedKeyboardBottomSheet(BuildContext context, double scale) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppPageHeader(
                      title: strings.windowsKeyboard,
                      subtitle: strings.windowsKeyboardHint,
                      icon: Icons.keyboard_rounded,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      strings.shellSymbols,
                      style: TextStyle(
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _keyWrap(context, const [
                      _KeySpec('|', '|'),
                      _KeySpec('~', '~'),
                      _KeySpec('/', '/'),
                      _KeySpec('\\', '\\'),
                      _KeySpec('\$', '\$'),
                      _KeySpec('&', '&'),
                      _KeySpec('>', '>'),
                      _KeySpec('<', '<'),
                      _KeySpec(';', ';'),
                      _KeySpec('-', '-'),
                      _KeySpec('_', '_'),
                      _KeySpec('`', '`'),
                      _KeySpec("'", "'"),
                      _KeySpec('"', '"'),
                      _KeySpec('*', '*'),
                      _KeySpec('#', '#'),
                      _KeySpec('=', '='),
                      _KeySpec('%', '%'),
                    ], scale),
                    const SizedBox(height: 16),
                    Text(
                      strings.navigationShell,
                      style: TextStyle(
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _keyWrap(context, const [
                      _KeySpec('ESC', '\x1b'),
                      _KeySpec('TAB', '\t'),
                      _KeySpec('ENTER', '\r'),
                      _KeySpec('BKSP', '\x7f'),
                      _KeySpec('↑', '\x1b[A'),
                      _KeySpec('↓', '\x1b[B'),
                      _KeySpec('←', '\x1b[D'),
                      _KeySpec('→', '\x1b[C'),
                      _KeySpec('HOME', '\x1b[H'),
                      _KeySpec('END', '\x1b[F'),
                      _KeySpec('PGUP', '\x1b[5~'),
                      _KeySpec('PGDN', '\x1b[6~'),
                      _KeySpec('INS', '\x1b[2~'),
                      _KeySpec('DEL', '\x1b[3~'),
                      _KeySpec('SPACE', ' '),
                    ], scale),
                    const SizedBox(height: 16),
                    Text(
                      strings.controlShortcuts,
                      style: TextStyle(
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _keyWrap(context, const [
                      _KeySpec('CTRL+C', '\x03'),
                      _KeySpec('CTRL+Z', '\x1a'),
                      _KeySpec('CTRL+L', '\x0c'),
                      _KeySpec('CTRL+D', '\x04'),
                      _KeySpec('CTRL+A', '\x01'),
                      _KeySpec('CTRL+E', '\x05'),
                      _KeySpec('CTRL+U', '\x15'),
                      _KeySpec('CTRL+K', '\x0b'),
                      _KeySpec('CTRL+W', '\x17'),
                      _KeySpec('CTRL+R', '\x12'),
                      _KeySpec('CTRL+\\', '\x1c'),
                      _KeySpec('ALT+B', '\x1bb'),
                      _KeySpec('ALT+F', '\x1bf'),
                      _KeySpec('ALT+D', '\x1bd'),
                    ], scale),
                    const SizedBox(height: 16),
                    Text(
                      strings.functionKeys,
                      style: TextStyle(
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _keyGroup(context, const [
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
                    ], scale),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 88,
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
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: IconButton(
                            icon: Icon(Icons.send, size: 20 * scale),
                            tooltip: strings.send,
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.1),
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
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
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (label, command)),
            child: Text(strings.add),
          ),
        ],
      ),
    );

    if (result == null || !context.mounted) return;

    await context.read<ShortcutCommandService>().addCustomCommand(
      result.$1,
      result.$2,
    );
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
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(strings.remove),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await context.read<ShortcutCommandService>().removeCustomCommand(
      command.id,
    );
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
