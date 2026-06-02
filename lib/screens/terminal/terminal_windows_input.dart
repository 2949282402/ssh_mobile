part of '../terminal_screen.dart';

extension _TerminalWindowsInput on _TerminalScreenState {
  Widget _buildWindowsCommandInput(
    BuildContext context,
    Color toolbarColor,
    TerminalStrings strings,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor =
        isDark ? const Color(0xFF30363D) : const Color(0xFFD0D7DE);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: toolbarColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: _handleWindowsCommandInputKeyEvent,
                child: TextField(
                  controller: _windowsCommandInputController,
                  focusNode: _windowsCommandInputFocusNode,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: strings.multilineHint,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    suffixText: 'Enter',
                    suffixStyle: TextStyle(
                      color: colorScheme.onSurface.withValues(alpha: 0.48),
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              height: 38,
              width: 42,
              child: IconButton(
                icon: const Icon(Icons.send, size: 20),
                tooltip: strings.send,
                onPressed: _sendWindowsCommandInput,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _requestWindowsAwareTerminalFocus() {
    if (_isWindowsTerminalTarget) {
      _windowsCommandInputFocusNode.requestFocus();
    } else {
      _terminalFocusNode.requestFocus();
    }
  }

  KeyEventResult _handleWindowsCommandInputKeyEvent(
    FocusNode focusNode,
    KeyEvent event,
  ) {
    if (!_isWindowsTerminalTarget || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyC &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      final inputSelection = _windowsCommandInputController.selection;
      if (inputSelection.isValid && !inputSelection.isCollapsed) {
        return KeyEventResult.ignored;
      }

      final selectedText = _selectedTerminalText();
      if (selectedText.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: selectedText));
        return KeyEventResult.handled;
      }
      return _sendTerminalKey(TerminalKey.keyC, ctrl: true);
    }

    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    final value = _windowsCommandInputController.value;
    if (!value.composing.isCollapsed) return KeyEventResult.ignored;

    if (HardwareKeyboard.instance.isShiftPressed) {
      _insertWindowsCommandInputText('\n');
      return KeyEventResult.handled;
    }

    _sendWindowsCommandInput();
    return KeyEventResult.handled;
  }

  void _insertWindowsCommandInputText(String text) {
    final value = _windowsCommandInputController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    final offset = selection.start + text.length;
    _windowsCommandInputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  void _sendWindowsCommandInput() {
    final text = _windowsCommandInputController.text;
    if (text.isEmpty) {
      _sendTerminalKey(TerminalKey.enter);
      return;
    }

    context.read<SshService>().sendData(widget.sessionId, '$text\r');
    _windowsCommandInputController.clear();
    _requestWindowsAwareTerminalFocus();
  }
}
