import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/terminal/models/terminal_keyboard_models.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('QWERTY layout covers digits and every Latin letter', () {
    final keys = TerminalKeyboardLayouts.letters.expand((row) => row).toList();

    expect(keys.where((key) => key.id.startsWith('digit_')), hasLength(10));
    for (final letter in 'abcdefghijklmnopqrstuvwxyz'.split('')) {
      final key = keys.singleWhere((item) => item.id == letter);
      expect(key.text, letter);
      expect(key.shiftedText, letter.toUpperCase());
      expect(key.terminalKey, isNotNull);
    }
  });

  test('navigation and function layers expose PC terminal keys', () {
    final navigation = TerminalKeyboardLayouts.navigation
        .expand((row) => row)
        .toList();
    final functions = TerminalKeyboardLayouts.function
        .expand((row) => row)
        .toList();

    expect(
      navigation.singleWhere((key) => key.id == 'tab').terminalKey,
      TerminalKey.tab,
    );
    expect(functions, hasLength(12));
    expect(functions.first.terminalKey, TerminalKey.f1);
    expect(functions.last.terminalKey, TerminalKey.f12);
  });
}
