import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/features/ai_chat/views/widgets/message_attachments_wrap.dart';
import 'package:ssh_mobile/features/ai_chat/views/widgets/message_bubble.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  testWidgets('message actions keep 48 dp targets and wrap on narrow width', (
    tester,
  ) async {
    var regenerated = false;
    var branched = false;

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettings(),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 180,
                child: MessageActions(
                  isUser: false,
                  isError: false,
                  assistantText: 'A reply that can be copied.',
                  onRegenerate: () => regenerated = true,
                  onBranch: () => branched = true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final buttons = find.byType(IconButton);
    expect(buttons, findsNWidgets(4));
    for (var index = 0; index < 4; index++) {
      expect(tester.getSize(buttons.at(index)), const Size(48, 48));
    }
    expect(
      tester.getTopLeft(find.byTooltip('创建分支')).dy,
      greaterThan(tester.getTopLeft(find.byTooltip('复制回复')).dy),
    );

    await tester.tap(find.byTooltip('重新生成'));
    await tester.tap(find.byTooltip('创建分支'));
    expect(regenerated, isTrue);
    expect(branched, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('user message actions localize edit and continue tooltips', (
    tester,
  ) async {
    var edited = false;
    var continued = false;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettings(),
        child: MaterialApp(
          home: Scaffold(
            body: MessageActions(
              isUser: true,
              isError: false,
              onEditUser: () => edited = true,
              onContinueTimeout: () => continued = true,
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('编辑并重发'), findsOneWidget);
    expect(find.byTooltip('继续生成'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑并重发'));
    await tester.tap(find.byTooltip('继续生成'));
    expect(edited, isTrue);
    expect(continued, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sent attachment names ellipsize inside the message width', (
    tester,
  ) async {
    const fileName =
        'production-configuration-with-an-extremely-long-name-and-no-breaks.yaml';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: MessageAttachmentsWrap(
              attachments: [
                AiChatAttachment(
                  fileName: fileName,
                  mimeType: 'text/yaml',
                  sizeBytes: 4096,
                  dataBase64: '',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text(fileName));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}
