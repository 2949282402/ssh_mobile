import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/features/ai_chat/views/widgets/message_bubble.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  testWidgets('message editor remains usable above a landscape keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 660);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => EditUserMessageDialog(
                      initialText: List.filled(
                        24,
                        'A long message line that needs editing.',
                      ).join('\n'),
                      strings: AiStrings(AppLanguage.en),
                    ),
                  );
                },
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey<String>('edit-message-field'));
    final cancel = find.byKey(const ValueKey<String>('edit-message-cancel'));
    final submit = find.byKey(const ValueKey<String>('edit-message-submit'));
    expect(field, findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(submit, findsOneWidget);
    expect(tester.getSize(field).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(submit).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);

    await tester.enterText(field, '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.enterText(field, 'Updated message\nwith details');
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(result, 'Updated message\nwith details');
    expect(find.byType(EditUserMessageDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
