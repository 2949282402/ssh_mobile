import 'package:flutter/material.dart';
import '../../test_utils/ai_port_adapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  testWidgets('RAG sheet respects mobile safe area and long text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    final settings = AppSettings();
    addTearDown(settings.dispose);
    var managed = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (sheetContext) => ChatRagSheetContent(
                      strings: AiStrings(AppLanguage.en),
                      appSettings: aiSettingsPort(settings),
                      hasAliyunKey: false,
                      onManage: () {
                        managed = true;
                        Navigator.pop(sheetContext);
                      },
                    ),
                  );
                },
                child: const Text('Open RAG'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open RAG'));
    await tester.pumpAndSettle();
    final close = find.byKey(const ValueKey<String>('chat-rag-close'));
    final enabled = find.byKey(const ValueKey<String>('chat-rag-enabled'));
    final manage = find.byKey(const ValueKey<String>('chat-rag-manage'));
    expect(find.text('Knowledge retrieval'), findsOneWidget);
    expect(close, findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(manage).height, greaterThanOrEqualTo(48));
    expect(tester.getRect(manage).bottom, lessThanOrEqualTo(700 - 24));
    expect(tester.takeException(), isNull);

    await tester.tap(enabled);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-rag-mode')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-rag-top-n')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(manage);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    expect(managed, isTrue);
    expect(find.byType(ChatRagSheetContent), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing while RAG persistence completes is safe', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => ChatRagSheetContent(
                    strings: AiStrings(AppLanguage.zh),
                    appSettings: aiSettingsPort(settings),
                    hasAliyunKey: false,
                    onManage: () {},
                  ),
                );
              },
              child: const Text('Open RAG'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open RAG'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('chat-rag-enabled')));
    await tester.tap(find.byKey(const ValueKey<String>('chat-rag-close')));
    await tester.pumpAndSettle();

    expect(find.byType(ChatRagSheetContent), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
