import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/llm_provider/llm_api_format.dart';
import 'package:ssh_mobile/services/storage_service.dart';

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

  testWidgets('system back confirms before discarding LLM settings edits', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettings(),
        child: ShadTheme(
          data: ShadThemeData(brightness: Brightness.light),
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        fullscreenDialog: true,
                        builder: (_) => const LlmSettingsScreen(
                          initialSettings: settings,
                          initialModels: ['example-model'],
                          initialBaseUrlHistory: [],
                          initialApiKeyHistory: [],
                        ),
                      ),
                    );
                  },
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.byType(LlmSettingsScreen), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).first,
      'https://changed.example.com',
    );
    await tester.pump();

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
}
