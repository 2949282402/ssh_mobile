import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';

void main() {
  testWidgets('attachments decode safely and images open a full preview', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const imageName = 'server-dashboard.png';
    const brokenName = 'broken-screenshot.png';
    const fileName = 'production-notes.txt';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MessageAttachmentsWrap(
              attachments: [
                AiChatAttachment(
                  fileName: imageName,
                  mimeType: 'image/png',
                  sizeBytes: 68,
                  dataBase64:
                      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                ),
                AiChatAttachment(
                  fileName: brokenName,
                  mimeType: 'image/png',
                  sizeBytes: 4,
                  dataBase64: '%%%invalid-base64%%%',
                ),
                AiChatAttachment(
                  fileName: fileName,
                  mimeType: 'text/plain',
                  sizeBytes: 2048,
                  dataBase64: '',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final preview = find.bySemanticsLabel('预览图片 $imageName');
    expect(preview, findsOneWidget);
    expect(find.bySemanticsLabel('图片预览不可用 $brokenName'), findsOneWidget);
    expect(
      find.bySemanticsLabel('文件附件 $fileName，text/plain，2.0 KB'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text(imageName), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
