import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('background scroll requests preserve the user reading position', () {
    expect(
      shouldFollowChatScrollRequest(explicit: false, isUserAtBottom: false),
      isFalse,
    );
    expect(
      shouldFollowChatScrollRequest(explicit: false, isUserAtBottom: true),
      isTrue,
    );
    expect(
      shouldFollowChatScrollRequest(explicit: true, isUserAtBottom: false),
      isTrue,
    );
  });

  testWidgets('jump button is accessible and works after generation ends', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(right: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final controller = ScrollController();
    final atBottom = ValueNotifier(false);
    addTearDown(controller.dispose);
    addTearDown(atBottom.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _jumpButtonHost(
        controller: controller,
        atBottom: atBottom,
        strings: const AiStrings(AppLanguage.en),
        textScale: 2,
        onPressed: () {
          controller.jumpTo(controller.position.maxScrollExtent);
          atBottom.value = true;
        },
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('chat-jump-to-bottom'));
    expect(button, findsOneWidget);
    expect(tester.getSize(button), const Size.square(48));
    expect(find.byTooltip('Jump to latest message'), findsOneWidget);
    expect(
      tester.getSemantics(button),
      matchesSemantics(
        label: 'Jump to latest message',
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(tester.getTopRight(button).dx, closeTo(284, 0.01));
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);

    await tester.tap(button);
    await tester.pump();
    expect(controller.offset, controller.position.maxScrollExtent);
    expect(button, findsNothing);
    semantics.dispose();
  });

  testWidgets('jump button stays hidden at the bottom and for short content', (
    tester,
  ) async {
    final controller = ScrollController();
    final atBottom = ValueNotifier(true);
    addTearDown(controller.dispose);
    addTearDown(atBottom.dispose);

    await tester.pumpWidget(
      _jumpButtonHost(
        controller: controller,
        atBottom: atBottom,
        strings: const AiStrings(AppLanguage.zh),
        itemCount: 1,
        onPressed: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('chat-jump-to-bottom')), findsNothing);
    atBottom.value = false;
    await tester.pump();
    expect(controller.position.maxScrollExtent, lessThanOrEqualTo(48));
    expect(find.byKey(const ValueKey('chat-jump-to-bottom')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('jump button stays above a 1.5K landscape keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 660);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final controller = ScrollController();
    final atBottom = ValueNotifier(false);
    addTearDown(controller.dispose);
    addTearDown(atBottom.dispose);

    await tester.pumpWidget(
      _jumpButtonHost(
        controller: controller,
        atBottom: atBottom,
        strings: const AiStrings(AppLanguage.zh),
        onPressed: () {},
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('chat-jump-to-bottom'));
    expect(tester.getSize(button), const Size.square(48));
    final visibleBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(tester.getBottomRight(button).dy, lessThanOrEqualTo(visibleBottom));
    expect(tester.takeException(), isNull);
  });
}

Widget _jumpButtonHost({
  required ScrollController controller,
  required ValueNotifier<bool> atBottom,
  required AiStrings strings,
  required VoidCallback onPressed,
  int itemCount = 100,
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
      body: Stack(
        children: [
          ListView.builder(
            controller: controller,
            itemExtent: 60,
            itemCount: itemCount,
            itemBuilder: (context, index) => Text('Message $index'),
          ),
          ChatJumpToBottomButton(
            scrollController: controller,
            isUserAtBottom: atBottom,
            onPressed: onPressed,
            strings: strings,
          ),
        ],
      ),
    ),
  );
}
