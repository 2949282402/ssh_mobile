import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'package:ssh_mobile/features/terminal/models/terminal_keyboard_models.dart';
import 'package:ssh_mobile/services/app_settings.dart';

class TerminalCustomKeyboard extends StatefulWidget {
  const TerminalCustomKeyboard({
    super.key,
    required this.strings,
    required this.controller,
    required this.onTerminalStroke,
    required this.onSubmit,
    required this.onCustomizeQuickKeys,
  });

  final TerminalStrings strings;
  final TextEditingController controller;
  final ValueChanged<TerminalKeyboardStroke> onTerminalStroke;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCustomizeQuickKeys;

  @override
  State<TerminalCustomKeyboard> createState() => _TerminalCustomKeyboardState();
}

class _TerminalCustomKeyboardState extends State<TerminalCustomKeyboard> {
  TerminalKeyboardMode _mode = TerminalKeyboardMode.compose;
  TerminalKeyboardLayer _layer = TerminalKeyboardLayer.letters;
  TerminalModifierState _shift = TerminalModifierState.off;
  TerminalModifierState _ctrl = TerminalModifierState.off;
  TerminalModifierState _alt = TerminalModifierState.off;

  bool get _shiftActive => _shift != TerminalModifierState.off;
  bool get _ctrlActive => _ctrl != TerminalModifierState.off;
  bool get _altActive => _alt != TerminalModifierState.off;

  @override
  Widget build(BuildContext context) {
    final rows = TerminalKeyboardLayouts.forLayer(_layer);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildModeBar(context),
        const SizedBox(height: 10),
        _buildComposer(context),
        const SizedBox(height: 12),
        _buildLayerBar(context),
        const SizedBox(height: 8),
        for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...[
          _buildKeyRow(context, rows[rowIndex], rowIndex),
          const SizedBox(height: 6),
        ],
        _buildModifierRow(context),
      ],
    );
  }

  Widget _buildModeBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: SegmentedButton<TerminalKeyboardMode>(
            key: const ValueKey('terminal-keyboard-mode'),
            segments: [
              ButtonSegment(
                value: TerminalKeyboardMode.compose,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: Text(widget.strings.keyboardComposeMode),
              ),
              ButtonSegment(
                value: TerminalKeyboardMode.direct,
                icon: const Icon(Icons.terminal_rounded, size: 18),
                label: Text(widget.strings.keyboardDirectMode),
              ),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: (values) {
              setState(() => _mode = values.first);
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox.square(
          dimension: 48,
          child: IconButton(
            key: const ValueKey('terminal-keyboard-customize-quick-keys'),
            tooltip: widget.strings.customizeQuickKeys,
            style: IconButton.styleFrom(
              backgroundColor: colors.primary.withValues(alpha: 0.1),
              foregroundColor: colors.primary,
            ),
            onPressed: widget.onCustomizeQuickKeys,
            icon: const Icon(Icons.tune_rounded),
          ),
        ),
      ],
    );
  }

  Widget _buildComposer(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 100,
              child: TextField(
                key: const ValueKey('terminal-custom-keyboard-input'),
                controller: widget.controller,
                expands: true,
                minLines: null,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                autocorrect: false,
                enableSuggestions: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                decoration: InputDecoration(
                  labelText: widget.strings.commandComposer,
                  hintText: widget.strings.multilineHint,
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    key: const ValueKey('terminal-custom-keyboard-paste'),
                    tooltip: widget.strings.pasteIntoCommand,
                    onPressed: _pasteClipboard,
                    icon: const Icon(Icons.content_paste_rounded, size: 20),
                  ),
                ),
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    key: const ValueKey('terminal-custom-keyboard-clear'),
                    tooltip: widget.strings.clearCommand,
                    onPressed: value.text.isEmpty
                        ? null
                        : widget.controller.clear,
                    icon: const Icon(Icons.backspace_outlined, size: 20),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    key: const ValueKey('terminal-custom-keyboard-send'),
                    onPressed: value.text.isEmpty ? null : _submitDraft,
                    icon: const Icon(Icons.send_rounded, size: 19),
                    label: Text(widget.strings.send),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildLayerBar(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = (constraints.maxWidth / 8).clamp(40.0, 48.0);
        return Row(
          children: [
            _layerButton(
              context,
              height,
              TerminalKeyboardLayer.letters,
              widget.strings.keyboardLetters,
              Icons.keyboard_rounded,
            ),
            const SizedBox(width: 4),
            _layerButton(
              context,
              height,
              TerminalKeyboardLayer.symbols,
              widget.strings.shellSymbols,
              Icons.code_rounded,
            ),
            const SizedBox(width: 4),
            _layerButton(
              context,
              height,
              TerminalKeyboardLayer.navigation,
              widget.strings.keyboardNavigation,
              Icons.navigation_rounded,
            ),
            const SizedBox(width: 4),
            _layerButton(
              context,
              height,
              TerminalKeyboardLayer.function,
              widget.strings.functionKeys,
              Icons.functions_rounded,
            ),
          ],
        );
      },
    );
  }

  Widget _layerButton(
    BuildContext context,
    double height,
    TerminalKeyboardLayer layer,
    String label,
    IconData icon,
  ) {
    final colors = Theme.of(context).colorScheme;
    final selected = _layer == layer;
    return Expanded(
      child: SizedBox(
        height: height,
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: Tooltip(
            message: label,
            child: FilledButton.tonal(
              key: ValueKey('terminal-keyboard-layer-${layer.name}'),
              style: FilledButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                elevation: selected ? 1.2 : 0.4,
                shadowColor: colors.shadow.withValues(alpha: 0.18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                side: BorderSide(
                  color: selected
                      ? colors.primary.withValues(alpha: 0.28)
                      : colors.outlineVariant.withValues(alpha: 0.72),
                ),
                backgroundColor: selected
                    ? colors.primaryContainer
                    : colors.surfaceContainerHigh,
                foregroundColor: selected
                    ? colors.onPrimaryContainer
                    : colors.onSurfaceVariant,
              ),
              onPressed: () => setState(() => _layer = layer),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16),
                    const SizedBox(width: 3),
                    Text(label),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyRow(
    BuildContext context,
    List<TerminalKeyboardKeySpec> row,
    int rowIndex,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final spacing = (width / 100).clamp(2.0, 5.0);
        final keyHeight = _keyHeightFor(width);
        final (leadingUnits, trailingUnits) = _rowInsets(rowIndex);
        final keyWidgets = <Widget>[];
        if (leadingUnits > 0) {
          keyWidgets.add(Spacer(flex: (leadingUnits * 20).round()));
        }
        for (var index = 0; index < row.length; index++) {
          final key = row[index];
          final button = _buildKey(context, key, keyHeight);
          keyWidgets.add(
            Expanded(flex: (key.flex * 20).round(), child: button),
          );
          if (index != row.length - 1) {
            keyWidgets.add(SizedBox(width: spacing));
          }
        }
        if (trailingUnits > 0) {
          keyWidgets.add(Spacer(flex: (trailingUnits * 20).round()));
        }
        return Row(children: keyWidgets);
      },
    );
  }

  (double, double) _rowInsets(int rowIndex) {
    if (_layer != TerminalKeyboardLayer.letters) return (0, 0);
    return switch (rowIndex) {
      0 => (0, 0),
      1 => (0.2, 0),
      2 => (0.55, 0.55),
      3 => (0.85, 0),
      _ => (0, 0),
    };
  }

  double _keyHeightFor(double width) {
    return (width / 10).clamp(32.0, 48.0);
  }

  ButtonStyle _keycapStyle(
    BuildContext context, {
    bool terminal = false,
    bool active = false,
    bool primary = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final background = primary || active
        ? colors.primary
        : terminal
        ? colors.secondaryContainer
        : colors.surfaceContainerHigh;
    final foreground = primary || active
        ? colors.onPrimary
        : terminal
        ? colors.onSecondaryContainer
        : colors.onSurface;
    return FilledButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      elevation: primary || active ? 1.6 : 0.6,
      shadowColor: colors.shadow.withValues(alpha: 0.22),
      backgroundColor: background,
      foregroundColor: foreground,
      side: BorderSide(
        color: primary || active
            ? colors.primary.withValues(alpha: 0.72)
            : colors.outlineVariant.withValues(alpha: 0.78),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    );
  }

  Widget _buildKey(
    BuildContext context,
    TerminalKeyboardKeySpec key,
    double height,
  ) {
    final label = key.labelFor(_shiftActive);
    return SizedBox(
      height: height,
      child: FilledButton.tonal(
        key: ValueKey('terminal-custom-key-${key.id}'),
        style: _keycapStyle(context, terminal: key.alwaysTerminal),
        onPressed: () => _handleKey(key),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModifierRow(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = (constraints.maxWidth / 100).clamp(2.0, 5.0);
        final height = _keyHeightFor(constraints.maxWidth);
        return Row(
          children: [
            Expanded(
              flex: 16,
              child: _modifierButton(
                'Shift',
                _shift,
                () => setState(() => _shift = _nextModifierState(_shift)),
                height: height,
                key: const ValueKey('terminal-custom-key-shift'),
              ),
            ),
            SizedBox(width: spacing),
            Expanded(
              flex: 12,
              child: _modifierButton(
                'Ctrl',
                _ctrl,
                () => setState(() => _ctrl = _nextModifierState(_ctrl)),
                height: height,
                key: const ValueKey('terminal-custom-key-ctrl'),
              ),
            ),
            SizedBox(width: spacing),
            Expanded(
              flex: 12,
              child: _modifierButton(
                'Alt',
                _alt,
                () => setState(() => _alt = _nextModifierState(_alt)),
                height: height,
                key: const ValueKey('terminal-custom-key-alt'),
              ),
            ),
            SizedBox(width: spacing),
            Expanded(
              flex: 50,
              child: SizedBox(
                height: height,
                child: FilledButton.tonal(
                  key: const ValueKey('terminal-custom-key-space'),
                  style: _keycapStyle(context),
                  onPressed: () => _handleTextKey(' '),
                  child: FittedBox(child: Text(widget.strings.keyboardSpace)),
                ),
              ),
            ),
            SizedBox(width: spacing),
            Expanded(
              flex: 16,
              child: SizedBox(
                height: height,
                child: FilledButton.tonal(
                  key: const ValueKey('terminal-custom-key-backspace'),
                  style: _keycapStyle(context, terminal: true),
                  onPressed: _handleBackspace,
                  child: Tooltip(
                    message: widget.strings.keyboardBackspace,
                    child: const FittedBox(
                      child: Icon(Icons.backspace_outlined, size: 19),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: spacing),
            Expanded(
              flex: 18,
              child: SizedBox(
                height: height,
                child: FilledButton(
                  key: const ValueKey('terminal-custom-key-enter'),
                  style: _keycapStyle(context, primary: true),
                  onPressed: _handleEnter,
                  child: Tooltip(
                    message: widget.strings.keyboardEnter,
                    child: const FittedBox(
                      child: Icon(Icons.keyboard_return_rounded, size: 20),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _modifierButton(
    String label,
    TerminalModifierState state,
    VoidCallback onPressed, {
    required double height,
    required Key key,
  }) {
    final active = state != TerminalModifierState.off;
    final suffix = switch (state) {
      TerminalModifierState.off => '',
      TerminalModifierState.once => ' •',
      TerminalModifierState.locked => ' 🔒',
    };
    return SizedBox(
      height: height,
      child: FilledButton(
        key: key,
        style: _keycapStyle(context, active: active),
        onPressed: onPressed,
        child: FittedBox(child: Text('$label$suffix')),
      ),
    );
  }

  TerminalModifierState _nextModifierState(TerminalModifierState current) {
    return switch (current) {
      TerminalModifierState.off => TerminalModifierState.once,
      TerminalModifierState.once => TerminalModifierState.locked,
      TerminalModifierState.locked => TerminalModifierState.off,
    };
  }

  void _handleKey(TerminalKeyboardKeySpec key) {
    if (_mode == TerminalKeyboardMode.compose && !_ctrlActive && !_altActive) {
      if (_handleComposeSpecialKey(key)) return;
      final text = key.textFor(_shiftActive);
      if (!key.alwaysTerminal && text != null) {
        _insertText(text);
        _consumeOneShotModifiers();
        return;
      }
    }
    _sendTerminalKey(key);
  }

  bool _handleComposeSpecialKey(TerminalKeyboardKeySpec key) {
    switch (key.id) {
      case 'backspace':
        _deleteBackward();
        return true;
      case 'delete':
        _deleteForward();
        return true;
      case 'left':
        _moveCursor(-1);
        return true;
      case 'right':
        _moveCursor(1);
        return true;
      case 'home':
        _moveCursorToBoundary(start: true);
        return true;
      case 'end':
        _moveCursorToBoundary(start: false);
        return true;
      case 'tab':
        if (_shiftActive) return false;
        _insertText('\t');
        return true;
      case 'enter':
        _handleEnter();
        return true;
    }
    return false;
  }

  void _sendTerminalKey(TerminalKeyboardKeySpec key) {
    final terminalKey = key.terminalKey;
    final text = key.textFor(_shiftActive);
    if (terminalKey == null && text == null) return;
    final sendAsTerminalKey = key.alwaysTerminal || text == null;
    widget.onTerminalStroke(
      TerminalKeyboardStroke(
        key: sendAsTerminalKey ? terminalKey : null,
        text: sendAsTerminalKey ? null : text,
        ctrl: _ctrlActive,
        alt: _altActive,
        shift: _shiftActive,
      ),
    );
    _consumeOneShotModifiers();
  }

  void _handleTextKey(String text) {
    if (_mode == TerminalKeyboardMode.compose && !_ctrlActive && !_altActive) {
      _insertText(text);
      _consumeOneShotModifiers();
      return;
    }
    widget.onTerminalStroke(
      TerminalKeyboardStroke(
        text: text,
        ctrl: _ctrlActive,
        alt: _altActive,
        shift: _shiftActive,
      ),
    );
    _consumeOneShotModifiers();
  }

  void _handleBackspace() {
    if (_mode == TerminalKeyboardMode.compose && !_ctrlActive && !_altActive) {
      _deleteBackward();
      return;
    }
    widget.onTerminalStroke(
      TerminalKeyboardStroke(
        key: TerminalKey.backspace,
        ctrl: _ctrlActive,
        alt: _altActive,
        shift: _shiftActive,
      ),
    );
    _consumeOneShotModifiers();
  }

  void _handleEnter() {
    if (_mode == TerminalKeyboardMode.compose && !_ctrlActive && !_altActive) {
      if (_shiftActive) {
        _insertText('\n');
        _consumeOneShotModifiers();
      } else {
        _submitDraft();
      }
      return;
    }
    widget.onTerminalStroke(
      TerminalKeyboardStroke(
        key: TerminalKey.enter,
        ctrl: _ctrlActive,
        alt: _altActive,
        shift: _shiftActive,
      ),
    );
    _consumeOneShotModifiers();
  }

  void _consumeOneShotModifiers() {
    if (_shift != TerminalModifierState.once &&
        _ctrl != TerminalModifierState.once &&
        _alt != TerminalModifierState.once) {
      return;
    }
    setState(() {
      if (_shift == TerminalModifierState.once) {
        _shift = TerminalModifierState.off;
      }
      if (_ctrl == TerminalModifierState.once) {
        _ctrl = TerminalModifierState.off;
      }
      if (_alt == TerminalModifierState.once) {
        _alt = TerminalModifierState.off;
      }
    });
  }

  void _insertText(String text) {
    final value = widget.controller.value;
    if (!value.composing.isCollapsed) return;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    widget.controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  void _deleteBackward() {
    final value = widget.controller.value;
    if (!value.composing.isCollapsed || value.text.isEmpty) return;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    if (!selection.isCollapsed) {
      _replaceSelection(value, selection, '');
      return;
    }
    if (selection.start == 0) return;
    final range = TextSelection(
      baseOffset: selection.start - 1,
      extentOffset: selection.start,
    );
    _replaceSelection(value, range, '');
  }

  void _deleteForward() {
    final value = widget.controller.value;
    if (!value.composing.isCollapsed || value.text.isEmpty) return;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    if (!selection.isCollapsed) {
      _replaceSelection(value, selection, '');
      return;
    }
    if (selection.start >= value.text.length) return;
    final range = TextSelection(
      baseOffset: selection.start,
      extentOffset: selection.start + 1,
    );
    _replaceSelection(value, range, '');
  }

  void _replaceSelection(
    TextEditingValue value,
    TextSelection selection,
    String replacement,
  ) {
    final next = value.text.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: selection.start + replacement.length,
      ),
    );
  }

  void _moveCursor(int delta) {
    final value = widget.controller.value;
    if (!value.composing.isCollapsed) return;
    final current = value.selection.isValid
        ? value.selection.extentOffset
        : value.text.length;
    final next = (current + delta).clamp(0, value.text.length);
    widget.controller.selection = TextSelection.collapsed(offset: next);
  }

  void _moveCursorToBoundary({required bool start}) {
    final text = widget.controller.text;
    widget.controller.selection = TextSelection.collapsed(
      offset: start ? 0 : text.length,
    );
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _insertText(text);
  }

  void _submitDraft() {
    final text = widget.controller.text;
    if (text.isEmpty) return;
    widget.onSubmit(text);
    widget.controller.clear();
  }
}
