import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('branch confirmation fits 320dp at 2x text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const strings = AiStrings(AppLanguage.en);
    bool? result;
    var closeCount = 0;

    await tester.pumpWidget(
      _confirmationHost(
        strings: strings,
        title: strings.createBranchTitle,
        message: strings.createBranchMessage,
        confirmLabel: strings.createBranchAction,
        onClosed: (value) {
          result = value;
          closeCount += 1;
        },
        textScale: 2,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-chat-confirmation')));
    await tester.pumpAndSettle();

    expect(find.text('Create a chat branch?'), findsOneWidget);
    expect(
      find.text('Creates a new chat branch from this message.'),
      findsOneWidget,
    );
    final cancel = find.byKey(const ValueKey('chat-action-cancel'));
    final confirm = find.byKey(const ValueKey('chat-action-confirm'));
    final titleRect = tester.getRect(find.text('Create a chat branch?'));
    expect(titleRect.left, greaterThanOrEqualTo(24));
    expect(titleRect.right, lessThanOrEqualTo(296));
    for (final action in [cancel, confirm]) {
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(closeCount, 1);

    await tester.tap(find.byKey(const ValueKey('open-chat-confirmation')));
    await tester.pumpAndSettle();
    final reopenedCancel = find.byKey(const ValueKey('chat-action-cancel'));
    await tester.tap(reopenedCancel);
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(closeCount, 2);

    await tester.tap(find.byKey(const ValueKey('open-chat-confirmation')));
    await tester.pumpAndSettle();
    final secondConfirm = find.byKey(const ValueKey('chat-action-confirm'));
    await tester.tap(secondConfirm);
    await tester.tap(secondConfirm, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(closeCount, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('regenerate confirmation stays above a 1.5K landscape keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 660);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    const strings = AiStrings(AppLanguage.zh);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    bool? result;

    await tester.pumpWidget(
      _confirmationHost(
        strings: strings,
        title: strings.regenerateReplyTitle,
        message: strings.regenerateReplyMessage,
        confirmLabel: strings.regenerateReplyAction,
        focusNode: focusNode,
        onClosed: (value) => result = value,
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    await tester.tap(find.byKey(const ValueKey('open-chat-confirmation')));
    await tester.pumpAndSettle();

    expect(focusNode.hasFocus, isFalse);
    expect(find.text('确认重新生成这条回复吗？'), findsOneWidget);
    expect(find.text('这会删除当前回复及其后的所有消息，并从该位置重新生成。'), findsOneWidget);
    final cancel = find.byKey(const ValueKey('chat-action-cancel'));
    final confirm = find.byKey(const ValueKey('chat-action-confirm'));
    for (final action in [cancel, confirm]) {
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    final visibleBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(tester.getBottomRight(confirm).dy, lessThanOrEqualTo(visibleBottom));
    expect(tester.takeException(), isNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(focusNode.hasFocus, isFalse);

    await tester.tap(find.byKey(const ValueKey('open-chat-confirmation')));
    await tester.pumpAndSettle();
    final reopenedConfirm = find.byKey(const ValueKey('chat-action-confirm'));
    await tester.tap(reopenedConfirm);
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(focusNode.hasFocus, isFalse);
  });
}

Widget _confirmationHost({
  required AiStrings strings,
  required String title,
  required String message,
  required String confirmLabel,
  required ValueChanged<bool> onClosed,
  FocusNode? focusNode,
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
      body: Column(
        children: [
          TextField(focusNode: focusNode),
          Builder(
            builder: (context) => FilledButton(
              key: const ValueKey('open-chat-confirmation'),
              onPressed: () async {
                final result = await showChatActionConfirmation(
                  context: context,
                  title: title,
                  message: message,
                  confirmLabel: confirmLabel,
                  strings: strings,
                );
                onClosed(result);
              },
              child: const Text('Open'),
            ),
          ),
        ],
      ),
    ),
  );
}
