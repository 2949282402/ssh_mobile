import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  Widget toolsHarness(double width) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ChatToolsBar(
              skillsLabel: 'Skills',
              serverLabel: 'Server',
              webViewLabel: 'WebView',
              imageLabel: 'Image',
              fileLabel: 'File',
              ragLabel: 'Knowledge',
              promptLabel: 'Prompt',
              planModeLabel: 'Plan',
              playbooksLabel: 'Playbooks',
              isPlanModeActive: false,
              onServerTap: () {},
              onSkillsTap: () {},
              onWebViewTap: () {},
              onImageTap: () {},
              onFileTap: () {},
              onRagTap: () {},
              onPromptTap: () {},
              onPlanModeTap: () {},
              onPlaybooksTap: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tool grid uses more columns when landscape width is available', (
    tester,
  ) async {
    await tester.pumpWidget(toolsHarness(720));

    final serverY = tester.getTopLeft(find.text('Server')).dy;
    expect(tester.getTopLeft(find.text('Knowledge')).dy, serverY);
    expect(tester.getTopLeft(find.text('Prompt')).dy, greaterThan(serverY));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(toolsHarness(320));
    final narrowServerY = tester.getTopLeft(find.text('Server')).dy;
    expect(tester.getTopLeft(find.text('WebView')).dy, narrowServerY);
    expect(
      tester.getTopLeft(find.text('Image')).dy,
      greaterThan(narrowServerY),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment remove action keeps a 48 dp target', (tester) async {
    var removed = false;
    const fileName = 'production-configuration-with-a-very-long-file-name.yaml';

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettings(),
        child: MaterialApp(
          home: Scaffold(
            body: AttachmentChip(
              attachment: const AiChatAttachment(
                fileName: fileName,
                mimeType: 'text/yaml',
                sizeBytes: 2048,
                dataBase64: '',
              ),
              onRemove: () => removed = true,
            ),
          ),
        ),
      ),
    );

    final removeFinder = find.byTooltip('移除附件 $fileName');
    expect(tester.getSize(removeFinder).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(removeFinder).height, greaterThanOrEqualTo(48));
    final fileNameText = tester.widget<Text>(find.text(fileName));
    expect(fileNameText.maxLines, 1);
    expect(fileNameText.overflow, TextOverflow.ellipsis);

    await tester.tap(removeFinder);
    expect(removed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
