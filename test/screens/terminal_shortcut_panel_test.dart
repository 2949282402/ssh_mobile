import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_shortcut_panel.dart';

void main() {
  test('adjusted reorder index follows Flutter reorder semantics', () {
    expect(TerminalShortcutPanel.adjustedReorderIndex(1, 4), 3);
    expect(TerminalShortcutPanel.adjustedReorderIndex(3, 1), 1);
    expect(TerminalShortcutPanel.adjustedReorderIndex(1, 1), 1);
  });
}
