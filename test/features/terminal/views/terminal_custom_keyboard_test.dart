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

  testWidgets('keyboard fits narrow screens without horizontal scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller, textScale: 2));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
      findsNothing,
    );

    for (final id in [
      'digit_1',
      'digit_0',
      'q',
      'p',
      'a',
      'l',
      'z',
      'slash',
      'shift',
      'ctrl',
      'alt',
      'space',
      'backspace',
      'enter',
    ]) {
      final rect = tester.getRect(
        find.byKey(ValueKey('terminal-custom-key-$id')),
      );
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(280.01));
    }
  });

  testWidgets('QWERTY rows and modifier widths follow physical proportions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller));

    final qLeft = tester
        .getTopLeft(find.byKey(const ValueKey('terminal-custom-key-q')))
        .dx;
    final aLeft = tester
        .getTopLeft(find.byKey(const ValueKey('terminal-custom-key-a')))
        .dx;
    final zLeft = tester
        .getTopLeft(find.byKey(const ValueKey('terminal-custom-key-z')))
        .dx;
    expect(aLeft, greaterThan(qLeft));
    expect(zLeft, greaterThan(aLeft));

    final shiftWidth = tester
        .getSize(find.byKey(const ValueKey('terminal-custom-key-shift')))
        .width;
    final ctrlWidth = tester
        .getSize(find.byKey(const ValueKey('terminal-custom-key-ctrl')))
        .width;
    final spaceWidth = tester
        .getSize(find.byKey(const ValueKey('terminal-custom-key-space')))
        .width;
    final enterWidth = tester
        .getSize(find.byKey(const ValueKey('terminal-custom-key-enter')))
        .width;
    expect(shiftWidth, greaterThan(ctrlWidth));
    expect(spaceWidth, greaterThan(shiftWidth * 2));
    expect(enterWidth, greaterThan(ctrlWidth));
  });

  testWidgets('key height grows with available width', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(280, 1000);
    await tester.pumpWidget(_host(controller: controller));
    final narrowHeight = tester
        .getSize(find.byKey(const ValueKey('terminal-custom-key-q')))
        .height;

    tester.view.physicalSize = const Size(800, 1000);
    await tester.pumpWidget(_host(controller: controller));
    final wideHeight = tester
        .getSize(find.byKey(const ValueKey('terminal-custom-key-q')))
        .height;

    expect(narrowHeight, lessThan(wideHeight));
    expect(wideHeight, 48);
  });

  testWidgets('keycaps use modern rounded elevated surfaces', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller));

    final key = tester.widget<FilledButton>(
      find.byKey(const ValueKey('terminal-custom-key-q')),
    );
    final shape = key.style?.shape?.resolve(const <WidgetState>{});
    final elevation = key.style?.elevation?.resolve(const <WidgetState>{});
    expect(shape, isA<RoundedRectangleBorder>());
    expect(
      (shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(9),
    );
    expect(elevation, greaterThan(0));
  });
}

Widget _host({
  required TextEditingController controller,
  List<TerminalKeyboardStroke>? strokes,
  List<String>? submitted,
  double textScale = 1,
}) {
  return MaterialApp(
    theme: AppTheme.lightThemeFor(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
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
