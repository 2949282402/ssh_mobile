import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:ssh_mobile/services/app_settings.dart';
import '../../test_utils/ai_port_adapters.dart';

void main() {
  Widget toolsHarness(
    double width, {
    bool planModeActive = false,
    bool planModeBusy = false,
    double textScale = 1,
    VoidCallback? onPlanModeTap,
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
              isPlanModeActive: planModeActive,
              isPlanModeBusy: planModeBusy,
              onServerTap: () {},
              onSkillsTap: () {},
              onWebViewTap: () {},
              onImageTap: () {},
              onFileTap: () {},
              onRagTap: () {},
              onPromptTap: () {},
              onPlanModeTap: onPlanModeTap ?? () {},
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
        child: Builder(
          builder: (context) => ListenableProvider<ai.AiSettingsPort>.value(
            value: aiSettingsPort(context.read<AppSettings>()),
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

  testWidgets('plan tool exposes selected and busy semantics at 2x text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;

    await tester.pumpWidget(
      toolsHarness(
        320,
        planModeActive: true,
        textScale: 2,
        onPlanModeTap: () => taps += 1,
      ),
    );
    await tester.pump();

    final plan = find.byKey(const ValueKey<String>('chat-tool-plan-mode'));
    expect(plan, findsOneWidget);
    expect(tester.getSize(plan).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(plan),
      matchesSemantics(
        label: 'Plan',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(plan);
    expect(taps, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      toolsHarness(
        320,
        planModeActive: true,
        planModeBusy: true,
        textScale: 2,
        onPlanModeTap: () => taps += 1,
      ),
    );
    await tester.pump();
    expect(
      tester.getSemantics(plan),
      matchesSemantics(
        label: 'Plan',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    await tester.tap(plan, warnIfMissed: false);
    expect(taps, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
