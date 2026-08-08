import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:feature_ai/ai_llm.dart';
import '../../test_utils/ai_port_adapters.dart';

void main() {
  const settings = AiConnectionSettings(
    baseUrl: 'https://api.example.com',
    model: 'example-model',
    contextWindowTokens: 259000,
    timeoutSeconds: 60,
    deepSeekThinkingEnabled: false,
    deepSeekReasoningEffort: 'medium',
    openAiReasoningEffort: 'medium',
    webSearchEnabled: false,
    webSearchMaxResults: 5,
    webSearchEngine: 'duckduckgo',
    quarkSearchEndpoint: '',
    hasQuarkApiKey: false,
    multiAgentEnabled: false,
    multiAgentMaxAgents: 2,
    postToolReviewEnabled: true,
    toolCallBudget: 20,
    maxImageSizeBytes: 5 * 1024 * 1024,
    maxFileSizeBytes: 10 * 1024 * 1024,
    hasApiKey: false,
    activeApiKeyId: null,
    activeApiKeyMasked: null,
    useCustomPrompts: false,
    customSystemPrompt: '',
    customPlannerPrompt: '',
    customOperatorPrompt: '',
    customExplorePrompt: '',
    customReviewerPrompt: '',
    customSummarizerPrompt: '',
    customCoordinatorPrompt: '',
    apiFormat: LlmApiFormat.openAiChatCompletions,
  );

  const settingsScreen = LlmSettingsScreen(
    initialSettings: settings,
    initialModels: ['example-model'],
    initialBaseUrlHistory: [],
    initialApiKeyHistory: [],
  );

  Widget testApp({required Widget home}) {
    return ChangeNotifierProvider(
      create: (_) => AppSettings(),
      child: Builder(
        builder: (context) => ListenableProvider<ai.AiSettingsPort>.value(
          value: aiSettingsPort(context.read<AppSettings>()),
          child: ShadTheme(
            data: ShadThemeData(brightness: Brightness.light),
            child: MaterialApp(home: home),
          ),
        ),
      ),
    );
  }

  testWidgets('system back confirms before discarding LLM settings edits', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (_) => settingsScreen,
                  ),
                );
              },
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.byType(LlmSettingsScreen), findsOneWidget);
    expect(find.text('关闭'), findsNothing);

    await tester.enterText(
      find.byType(TextField).first,
      'https://changed.example.com',
    );
    await tester.pump();
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('取消'), findsNothing);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('放弃设置更改？'), findsOneWidget);
    expect(find.byType(LlmSettingsScreen), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(ShadDialog), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('llm-settings-close')));
    await tester.pumpAndSettle();
    expect(find.text('放弃设置更改？'), findsOneWidget);

    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(find.byType(LlmSettingsScreen), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LLM settings prioritize essentials and adapt form width', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(1440, 3120);
      tester.view.devicePixelRatio = 3.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testApp(home: settingsScreen));
      await tester.pumpAndSettle();

      expect(find.text('连接与模型'), findsOneWidget);
      expect(find.text('API 协议格式'), findsOneWidget);
      expect(find.text('高级模型选项'), findsOneWidget);
      expect(find.text('辅助模型（可选）'), findsNothing);
      expect(find.text('Agent 行为'), findsOneWidget);
      expect(find.text('多 Agent 协作'), findsNothing);
      expect(tester.takeException(), isNull, reason: 'initial 2K layout');

      final form = find.byKey(const ValueKey<String>('llm-settings-form'));
      expect(tester.getSize(form).width, closeTo(411.43 - 28, 0.1));

      await tester.ensureVisible(find.text('高级模型选项'));
      await tester.tap(find.text('高级模型选项'));
      await tester.pumpAndSettle();
      expect(find.text('辅助模型（可选）'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'expanded 2K layout');

      final helperField = find.widgetWithText(TextField, '辅助模型（可选）');
      await tester.enterText(helperField, 'helper-model');
      await tester.ensureVisible(find.text('高级模型选项'));
      await tester.tap(find.text('高级模型选项'));
      await tester.pumpAndSettle();
      expect(find.text('辅助模型（可选）'), findsNothing);
      await tester.tap(find.text('高级模型选项'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(helperField).controller?.text,
        'helper-model',
      );

      tester.view.physicalSize = const Size(1280, 2856);
      tester.view.devicePixelRatio = 3;
      await tester.pumpAndSettle();
      expect(tester.getSize(form).width, closeTo(426.67 - 28, 0.1));
      expect(tester.takeException(), isNull, reason: '1.5K layout');

      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      expect(tester.getSize(form).width, 760);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(tester.takeException(), isNull, reason: 'desktop layout');
  });
}
