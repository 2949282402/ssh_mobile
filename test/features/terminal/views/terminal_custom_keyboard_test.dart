import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/terminal/models/terminal_keyboard_models.dart';
import 'package:ssh_mobile/features/terminal/views/widgets/terminal_custom_keyboard.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('one-shot Ctrl sends a terminal stroke and is consumed', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final strokes = <TerminalKeyboardStroke>[];

    await tester.pumpWidget(_host(controller: controller, strokes: strokes));

    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-ctrl')));
    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-a')));

    expect(strokes, hasLength(1));
    expect(strokes.single.key, isNull);
    expect(strokes.single.text, 'a');
    expect(strokes.single.ctrl, isTrue);
    expect(controller.text, isEmpty);

    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-a')));
    expect(controller.text, 'a');
  });

  testWidgets('Shift+Tab is sent with Shift modifier', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final strokes = <TerminalKeyboardStroke>[];

    await tester.pumpWidget(_host(controller: controller, strokes: strokes));

    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-shift')));
    await tester.tap(
      find.byKey(const ValueKey('terminal-keyboard-layer-navigation')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-tab')));

    expect(strokes, hasLength(1));
    expect(strokes.single.key, TerminalKey.tab);
    expect(strokes.single.shift, isTrue);
  });

  testWidgets('Shift+Enter adds a line and plain Enter submits', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'echo one');
    addTearDown(controller.dispose);
    final submitted = <String>[];

    await tester.pumpWidget(
      _host(controller: controller, submitted: submitted),
    );

    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-shift')));
    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-enter')));
    expect(controller.text, 'echo one\n');

    await tester.tap(find.byKey(const ValueKey('terminal-custom-key-enter')));
    expect(submitted, ['echo one\n']);
    expect(controller.text, isEmpty);
  });
}

Widget _host({
  required TextEditingController controller,
  List<TerminalKeyboardStroke>? strokes,
  List<String>? submitted,
}) {
  return MaterialApp(
    theme: AppTheme.lightThemeFor(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: TerminalCustomKeyboard(
          strings: const TerminalStrings(AppLanguage.en),
          controller: controller,
          onTerminalStroke: (stroke) => strokes?.add(stroke),
          onSubmit: (text) => submitted?.add(text),
          onCustomizeQuickKeys: () {},
        ),
      ),
    ),
  );
}
