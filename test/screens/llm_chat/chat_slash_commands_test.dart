import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('slash suggestions are localized and keep 48dp targets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: '/',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _slashPanelApp(
        controller: controller,
        strings: const AiStrings(AppLanguage.zh),
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byType(ChatSlashCommandsPanel),
      matching: find.byType(Scrollable),
    );
    const summaries = {
      'compact': '为下一次请求压缩上下文。',
      'tools': '限制当前对话可使用的工具。',
      'skills': '打开并管理本地 AI Skills。',
      'plan': '启用规划模式，并可同时提交请求。',
    };
    for (final entry in summaries.entries) {
      final tile = find.byKey(ValueKey('slash-command-${entry.key}'));
      await tester.scrollUntilVisible(tile, 80, scrollable: scrollable);
      expect(tile, findsOneWidget);
      expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
      expect(find.text(entry.value), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('slash selection preserves only supported arguments', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var stateChanges = 0;

    Future<void> pumpFor(String text, int cursorOffset) async {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: cursorOffset),
      );
      await tester.pumpWidget(
        _slashPanelApp(
          controller: controller,
          strings: const AiStrings(AppLanguage.en),
          onStateChanged: () => stateChanges += 1,
        ),
      );
      await tester.pump();
    }

    await pumpFor('/sk old-argument', 2);
    await tester.tap(find.byKey(const ValueKey('slash-command-skills')));
    expect(controller.text, '/skills');
    expect(controller.selection.baseOffset, controller.text.length);

    await pumpFor('/pl inspect nginx', 2);
    await tester.tap(find.byKey(const ValueKey('slash-command-plan')));
    expect(controller.text, '/plan inspect nginx');
    expect(controller.selection.baseOffset, controller.text.length);

    await pumpFor('/to', 3);
    await tester.tap(find.byKey(const ValueKey('slash-command-tools')));
    expect(controller.text, '/tools ');
    expect(controller.selection.baseOffset, controller.text.length);

    await pumpFor('/compact stale text', 3);
    await tester.tap(find.byKey(const ValueKey('slash-command-compact')));
    expect(controller.text, '/compact');
    expect(controller.selection.baseOffset, controller.text.length);
    expect(stateChanges, 4);

    await pumpFor('/plan inspect nginx', '/plan inspect nginx'.length);
    expect(find.byKey(const ValueKey('slash-command-plan')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _slashPanelApp({
  required TextEditingController controller,
  required AiStrings strings,
  VoidCallback? onStateChanged,
  double textScale = 1,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ChatSlashCommandsPanel(
          inputController: controller,
          strings: strings,
          onStateChanged: onStateChanged ?? () {},
        ),
      ),
    ),
  );
}
