part of 'terminal_screen.dart';

final _windowsForwardedTerminalKeys = <LogicalKeyboardKey, TerminalKey>{
  LogicalKeyboardKey.escape: TerminalKey.escape,
  LogicalKeyboardKey.tab: TerminalKey.tab,
  LogicalKeyboardKey.arrowUp: TerminalKey.arrowUp,
  LogicalKeyboardKey.arrowDown: TerminalKey.arrowDown,
  LogicalKeyboardKey.arrowLeft: TerminalKey.arrowLeft,
  LogicalKeyboardKey.arrowRight: TerminalKey.arrowRight,
  LogicalKeyboardKey.home: TerminalKey.home,
  LogicalKeyboardKey.end: TerminalKey.end,
  LogicalKeyboardKey.pageUp: TerminalKey.pageUp,
  LogicalKeyboardKey.pageDown: TerminalKey.pageDown,
  LogicalKeyboardKey.insert: TerminalKey.insert,
  LogicalKeyboardKey.delete: TerminalKey.delete,
  LogicalKeyboardKey.f1: TerminalKey.f1,
  LogicalKeyboardKey.f2: TerminalKey.f2,
  LogicalKeyboardKey.f3: TerminalKey.f3,
  LogicalKeyboardKey.f4: TerminalKey.f4,
  LogicalKeyboardKey.f5: TerminalKey.f5,
  LogicalKeyboardKey.f6: TerminalKey.f6,
  LogicalKeyboardKey.f7: TerminalKey.f7,
  LogicalKeyboardKey.f8: TerminalKey.f8,
  LogicalKeyboardKey.f9: TerminalKey.f9,
  LogicalKeyboardKey.f10: TerminalKey.f10,
  LogicalKeyboardKey.f11: TerminalKey.f11,
  LogicalKeyboardKey.f12: TerminalKey.f12,
  LogicalKeyboardKey.keyA: TerminalKey.keyA,
  LogicalKeyboardKey.keyB: TerminalKey.keyB,
  LogicalKeyboardKey.keyC: TerminalKey.keyC,
  LogicalKeyboardKey.keyD: TerminalKey.keyD,
  LogicalKeyboardKey.keyE: TerminalKey.keyE,
  LogicalKeyboardKey.keyF: TerminalKey.keyF,
  LogicalKeyboardKey.keyK: TerminalKey.keyK,
  LogicalKeyboardKey.keyL: TerminalKey.keyL,
  LogicalKeyboardKey.keyR: TerminalKey.keyR,
  LogicalKeyboardKey.keyU: TerminalKey.keyU,
  LogicalKeyboardKey.keyW: TerminalKey.keyW,
  LogicalKeyboardKey.keyZ: TerminalKey.keyZ,
};

extension _TerminalWindowsInput on _TerminalScreenState {
  Widget _buildWindowsCommandInput(
    BuildContext context,
    TerminalSessionViewModel viewModel,
    Color toolbarColor,
    TerminalStrings strings,
  ) {
    final colors = Theme.of(context).colorScheme;
    final panelColor = Color.alphaBlend(
      colors.surface.withValues(alpha: 0.86),
      toolbarColor,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: panelColor,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: viewModel.commandInputController,
          builder: (context, value, _) => LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 520 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.4;
              final editor = Focus(
                onKeyEvent: (node, event) =>
                    _handleWindowsCommandInputKeyEvent(node, event, viewModel),
                child: TextField(
                  key: const ValueKey('terminal-command-input'),
                  controller: viewModel.commandInputController,
                  focusNode: viewModel.commandInputFocusNode,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 6,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.none,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  style: const TextStyle(
                    fontFamily: 'Cascadia Mono',
                    fontFamilyFallback: [
                      'Consolas',
                      'Microsoft YaHei Mono',
                      'monospace',
                    ],
                  ),
                  onChanged: (_) =>
                      viewModel.resetCommandInputHistoryNavigation(),
                  decoration: InputDecoration(
                    labelText: strings.commandComposer,
                    hintText: strings.multilineHint,
                    helperText: compact ? null : strings.commandComposerHint,
                    prefixIcon: const Icon(Icons.terminal_rounded, size: 20),
                    isDense: true,
                  ),
                ),
              );
              final actions = _buildWindowsCommandInputActions(
                viewModel,
                strings,
                hasText: value.text.isNotEmpty,
                showSendLabel: !compact,
              );
              if (!compact) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: editor),
                    const SizedBox(width: 8),
                    actions,
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  editor,
                  const SizedBox(height: 6),
                  Text(
                    strings.commandComposerHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildWindowsCommandInputActions(
    TerminalSessionViewModel viewModel,
    TerminalStrings strings, {
    required bool hasText,
    required bool showSendLabel,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 48,
          child: IconButton(
            key: const ValueKey('terminal-command-paste'),
            icon: const Icon(Icons.content_paste_rounded, size: 20),
            tooltip: strings.pasteIntoCommand,
            onPressed: () async {
              await viewModel.pasteClipboardIntoCommandInput();
              viewModel.commandInputFocusNode.requestFocus();
            },
          ),
        ),
        SizedBox.square(
          dimension: 48,
          child: IconButton(
            key: const ValueKey('terminal-command-clear'),
            icon: const Icon(Icons.backspace_outlined, size: 20),
            tooltip: strings.clearCommand,
            onPressed: hasText ? viewModel.clearCommandInput : null,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          key: const ValueKey('terminal-command-send'),
          width: showSendLabel ? null : 48,
          height: 48,
          child: showSendLabel
              ? FilledButton.icon(
                  onPressed: () => _sendWindowsCommandInput(viewModel),
                  icon: const Icon(Icons.send_rounded, size: 19),
                  label: Text(strings.send),
                )
              : IconButton.filled(
                  onPressed: () => _sendWindowsCommandInput(viewModel),
                  icon: const Icon(Icons.send_rounded, size: 19),
                  tooltip: strings.send,
                ),
        ),
      ],
    );
  }

  void _requestWindowsAwareTerminalFocus(TerminalSessionViewModel viewModel) {
    if (_isWindowsTerminalTarget) {
      viewModel.commandInputFocusNode.requestFocus();
    } else {
      viewModel.terminalFocusNode.requestFocus();
    }
  }

  KeyEventResult _handleWindowsCommandInputKeyEvent(
    FocusNode focusNode,
    KeyEvent event,
    TerminalSessionViewModel viewModel,
  ) {
    if (!_isWindowsTerminalTarget || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final value = viewModel.commandInputController.value;
    final control = keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    final meta = keyboard.isMetaPressed;
    final hasSelection =
        value.selection.isValid && !value.selection.isCollapsed;

    if (event.logicalKey == LogicalKeyboardKey.keyC &&
        control &&
        !alt &&
        !meta) {
      if (hasSelection) return KeyEventResult.ignored;
      final selectedText = viewModel.getSelectedText();
      if (selectedText.isNotEmpty) {
        unawaited(Clipboard.setData(ClipboardData(text: selectedText)));
        return KeyEventResult.handled;
      }
      if (value.text.isNotEmpty) viewModel.clearCommandInput();
      return _sendTerminalKey(viewModel, TerminalKey.keyC, ctrl: true);
    }
    if (!value.composing.isCollapsed) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (keyboard.isShiftPressed) {
        viewModel.insertCommandInputText('\n');
      } else {
        _sendWindowsCommandInput(viewModel);
      }
      return KeyEventResult.handled;
    }
    if (!control && !alt && !meta) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
          _caretIsOnFirstCommandLine(value)) {
        if (viewModel.showPreviousCommandInput()) {
          return KeyEventResult.handled;
        }
        if (value.text.isEmpty) {
          return _sendTerminalKey(viewModel, TerminalKey.arrowUp);
        }
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
          _caretIsOnLastCommandLine(value)) {
        if (viewModel.showNextCommandInput()) {
          return KeyEventResult.handled;
        }
        if (value.text.isEmpty) {
          return _sendTerminalKey(viewModel, TerminalKey.arrowDown);
        }
      }
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        if (value.text.isEmpty) {
          return _sendTerminalKey(viewModel, TerminalKey.tab);
        }
        viewModel.insertCommandInputText('\t');
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (value.text.isNotEmpty) {
          viewModel.clearCommandInput();
          return KeyEventResult.handled;
        }
        return _sendTerminalKey(viewModel, TerminalKey.escape);
      }
    }

    final terminalKey = _windowsForwardedTerminalKeys[event.logicalKey];
    final keyId = event.logicalKey.keyId;
    final isFunctionKey =
        keyId >= LogicalKeyboardKey.f1.keyId &&
        keyId <= LogicalKeyboardKey.f12.keyId;
    if (terminalKey != null &&
        (isFunctionKey || (value.text.isEmpty && (control || alt)))) {
      return _sendTerminalKey(
        viewModel,
        terminalKey,
        ctrl: control,
        alt: alt,
        shift: keyboard.isShiftPressed,
      );
    }
    return KeyEventResult.ignored;
  }

  bool _caretIsOnFirstCommandLine(TextEditingValue value) {
    if (!value.selection.isValid || !value.selection.isCollapsed) return false;
    return !value.text
        .substring(0, value.selection.extentOffset)
        .contains('\n');
  }

  bool _caretIsOnLastCommandLine(TextEditingValue value) {
    if (!value.selection.isValid || !value.selection.isCollapsed) return false;
    return !value.text.substring(value.selection.extentOffset).contains('\n');
  }

  void _sendWindowsCommandInput(TerminalSessionViewModel viewModel) {
    viewModel.submitCommandInput();
    _requestWindowsAwareTerminalFocus(viewModel);
  }

  KeyEventResult _sendTerminalKey(
    TerminalSessionViewModel viewModel,
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    final handled = viewModel.terminal.keyInput(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
    );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }
}
