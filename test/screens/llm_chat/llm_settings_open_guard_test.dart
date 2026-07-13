import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/llm_provider/llm_api_format.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LLM settings opening is single-flight and safely retryable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = originalPlatform;
    });
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final storage = _GuardedSettingsStorage();
    final settings = AppSettings();
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    final logs = AppLogService.instance;
    logs.clear();
    addTearDown(logs.clear);

    try {
      await storage.init();
      await settings.init();
      await settings.toggleLanguage();
      final ssh = SshService(storage);
      final sftp = SftpService(storage);
      final monitor = PerformanceMonitorService(ssh, storage);
      final playbooks = PlaybookService(
        storageService: storage,
        sshService: ssh,
      );
      final rag = RagService(storageService: storage);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<StorageService>.value(value: storage),
            ChangeNotifierProvider<SshService>.value(value: ssh),
            ChangeNotifierProvider<SftpService>.value(value: sftp),
            ChangeNotifierProvider<PerformanceMonitorService>.value(
              value: monitor,
            ),
            ChangeNotifierProvider<PlaybookService>.value(value: playbooks),
            ChangeNotifierProvider<RagService>.value(value: rag),
            ChangeNotifierProvider<AppSettings>.value(value: settings),
          ],
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (context, isActive, child) => Offstage(
                offstage: !isActive,
                child: LlmChatScreen(active: isActive),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final baselineLoads = storage.settingsLoads;
      final openSettings = find.byKey(const ValueKey('chat-open-llm-settings'));
      final openSettingsButton = find.byKey(
        const ValueKey('chat-open-llm-settings-button'),
      );
      expect(openSettings, findsOneWidget);
      expect(tester.getSize(openSettings).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(openSettings).width, greaterThanOrEqualTo(48));

      final gate = storage.blockNextLoad();
      await tester.tap(openSettingsButton);
      await tester.tap(openSettingsButton);
      expect(storage.settingsLoads, baselineLoads + 1);
      await tester.pump();
      expect(tester.widget<IconButton>(openSettingsButton).onPressed, isNull);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LlmSettingsScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('llm-settings-close')));
      await tester.pumpAndSettle();
      expect(find.byType(LlmSettingsScreen), findsNothing);
      expect(
        tester.widget<IconButton>(openSettingsButton).onPressed,
        isNotNull,
      );

      final inactiveGate = storage.blockNextLoad();
      await tester.tap(openSettingsButton);
      await tester.pump();
      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      inactiveGate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LlmSettingsScreen), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(storage.settingsLoads, baselineLoads + 2);
      expect(
        tester.widget<IconButton>(openSettingsButton).onPressed,
        isNotNull,
      );

      final inactiveFailureGate = storage.blockNextLoad();
      storage.failNextLoad = true;
      await tester.tap(openSettingsButton);
      await tester.pump();
      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      inactiveFailureGate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LlmSettingsScreen), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(storage.settingsLoads, baselineLoads + 3);
      expect(
        tester.widget<IconButton>(openSettingsButton).onPressed,
        isNotNull,
      );

      logs.clear();
      storage.failNextLoad = true;
      await tester.tap(openSettingsButton);
      await tester.pumpAndSettle();
      expect(
        find.text('Unable to open LLM settings. Try again.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(r'C:\private\llm-settings.json'),
        findsNothing,
      );
      expect(find.byType(LlmSettingsScreen), findsNothing);
      expect(
        tester.widget<IconButton>(openSettingsButton).onPressed,
        isNotNull,
      );
      final openFailure = logs.entries.singleWhere(
        (entry) => entry.message == 'Failed to open LLM settings',
      );
      expect(openFailure.normalizedLevel, AppLogLevel.error);
      expect(
        logs.entries.map((entry) => entry.text).join('\n'),
        isNot(contains(r'C:\private\llm-settings.json')),
      );

      await tester.tap(openSettingsButton);
      await tester.pumpAndSettle();
      expect(find.byType(LlmSettingsScreen), findsOneWidget);
      expect(storage.settingsLoads, baselineLoads + 5);
      await tester.tap(find.byKey(const ValueKey('llm-settings-close')));
      await tester.pumpAndSettle();

      logs.clear();
      final viewModel = tester
          .element(openSettingsButton)
          .read<AiChatViewModel>();
      final originalModel = viewModel.activeChat!.model;
      final baselineChatSaves = storage.chatSaveAttempts;
      storage.failNextChatSave = true;
      await tester.tap(openSettingsButton);
      await tester.pumpAndSettle();
      final modelField = find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButtonFormField<String> &&
            widget.decoration.labelText == 'Model',
      );
      expect(modelField, findsOneWidget);
      await tester.tap(modelField);
      await tester.pumpAndSettle();
      await tester.tap(find.text(_GuardedSettingsStorage.alternateModel).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Settings were saved, but the active chat could not update. '
          'Try again or start a new chat.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Unable to open LLM settings. Try again.'),
        findsNothing,
      );
      expect(find.byType(LlmSettingsScreen), findsNothing);
      final applyFailure = logs.entries.singleWhere(
        (entry) => entry.message == 'Failed to apply saved LLM settings',
      );
      expect(applyFailure.normalizedLevel, AppLogLevel.error);
      expect(
        logs.entries.map((entry) => entry.text).join('\n'),
        isNot(contains(r'C:\private\active-chat.json')),
      );
      expect(storage.chatSaveAttempts, baselineChatSaves + 1);
      expect(viewModel.activeChat!.model, originalModel);

      ScaffoldMessenger.of(
        tester.element(openSettingsButton),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(openSettingsButton);
      await tester.pumpAndSettle();
      final baseUrlField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Base URL',
      );
      expect(baseUrlField, findsOneWidget);
      await tester.enterText(baseUrlField, 'https://api.retry.example/v1');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.byType(LlmSettingsScreen), findsNothing);
      expect(storage.chatSaveAttempts, baselineChatSaves + 2);
      expect(
        viewModel.activeChat!.model,
        _GuardedSettingsStorage.alternateModel,
      );

      logs.clear();
      await tester.tap(openSettingsButton);
      await tester.pumpAndSettle();
      await tester.enterText(
        baseUrlField,
        'https://private.example/v1?token=top-secret-value',
      );
      await tester.pump();
      storage.failNextSettingsSave = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final settingsError = find.byKey(const ValueKey('llm-settings-error'));
      expect(settingsError, findsOneWidget);
      expect(
        find.descendant(
          of: settingsError,
          matching: find.text(
            'Unable to save LLM settings. Check the values and try again.',
          ),
        ),
        findsOneWidget,
      );
      final saveFailure = logs.entries.singleWhere(
        (entry) => entry.message == 'LLM settings save failed',
      );
      expect(saveFailure.normalizedLevel, AppLogLevel.error);
      final saveLogText = logs.entries.map((entry) => entry.text).join('\n');
      expect(saveLogText, isNot(contains('top-secret-value')));
      expect(saveLogText, isNot(contains('private.example')));
      expect(saveLogText, isNot(contains(r'C:\private\llm-config.json')));
      expect(
        saveLogText,
        isNot(contains(_GuardedSettingsStorage.alternateModel)),
      );
      await tester.enterText(baseUrlField, 'https://api.retry.example/v1');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('llm-settings-close')));
      await tester.pumpAndSettle();
      expect(find.byType(LlmSettingsScreen), findsNothing);

      final disposeGate = storage.blockNextLoad();
      await tester.tap(openSettingsButton);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      disposeGate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      storage.releasePendingLoads();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = originalPlatform;
      settings.dispose();
      storage.dispose();
    }
  });
}

class _GuardedSettingsStorage extends StorageService {
  static const alternateModel = 'settings-apply-test-model';

  int settingsLoads = 0;
  int chatSaveAttempts = 0;
  bool failNextLoad = false;
  bool failNextChatSave = false;
  bool failNextSettingsSave = false;
  Completer<void>? _nextLoadGate;
  final List<Completer<void>> _loadGates = [];

  Completer<void> blockNextLoad() {
    final gate = Completer<void>();
    _loadGates.add(gate);
    return _nextLoadGate = gate;
  }

  void releasePendingLoads() {
    for (final gate in _loadGates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    settingsLoads += 1;
    final gate = _nextLoadGate;
    if (gate != null) {
      _nextLoadGate = null;
      await gate.future;
    }
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError(r'failed to read C:\private\llm-settings.json');
    }
    return super.loadAiConnectionSettings();
  }

  @override
  Future<List<String>> loadCachedAiModels({String? baseUrl}) async {
    return const ['deepseek-v4-flash', alternateModel];
  }

  @override
  Future<void> saveAiConnectionSettings({
    required String baseUrl,
    required String model,
    String? helperModel,
    String? auditModel,
    String? modelFallbackPolicy,
    int? contextWindowTokens,
    int? timeoutSeconds,
    bool? deepSeekThinkingEnabled,
    String? deepSeekReasoningEffort,
    String? openAiReasoningEffort,
    bool? webSearchEnabled,
    int? webSearchMaxResults,
    String? webSearchEngine,
    bool? multiAgentEnabled,
    int? multiAgentMaxAgents,
    bool? postToolReviewEnabled,
    int? toolCallBudget,
    String? agentLoopMode,
    int? maxImageSizeBytes,
    int? maxFileSizeBytes,
    String? apiKey,
    String? selectedApiKeyId,
    bool clearApiKey = false,
    String? quarkSearchEndpoint,
    String? quarkApiKey,
    bool clearQuarkApiKey = false,
    bool? useCustomPrompts,
    String? customSystemPrompt,
    String? customPlannerPrompt,
    String? customOperatorPrompt,
    String? customExplorePrompt,
    String? customReviewerPrompt,
    String? customSummarizerPrompt,
    String? customCoordinatorPrompt,
    LlmApiFormat? apiFormat,
  }) async {
    if (failNextSettingsSave) {
      failNextSettingsSave = false;
      throw StateError(
        r'failed to write C:\private\llm-config.json?token=raw-secret',
      );
    }
    await super.saveAiConnectionSettings(
      baseUrl: baseUrl,
      model: model,
      helperModel: helperModel,
      auditModel: auditModel,
      modelFallbackPolicy: modelFallbackPolicy,
      contextWindowTokens: contextWindowTokens,
      timeoutSeconds: timeoutSeconds,
      deepSeekThinkingEnabled: deepSeekThinkingEnabled,
      deepSeekReasoningEffort: deepSeekReasoningEffort,
      openAiReasoningEffort: openAiReasoningEffort,
      webSearchEnabled: webSearchEnabled,
      webSearchMaxResults: webSearchMaxResults,
      webSearchEngine: webSearchEngine,
      multiAgentEnabled: multiAgentEnabled,
      multiAgentMaxAgents: multiAgentMaxAgents,
      postToolReviewEnabled: postToolReviewEnabled,
      toolCallBudget: toolCallBudget,
      agentLoopMode: agentLoopMode,
      maxImageSizeBytes: maxImageSizeBytes,
      maxFileSizeBytes: maxFileSizeBytes,
      apiKey: apiKey,
      selectedApiKeyId: selectedApiKeyId,
      clearApiKey: clearApiKey,
      quarkSearchEndpoint: quarkSearchEndpoint,
      quarkApiKey: quarkApiKey,
      clearQuarkApiKey: clearQuarkApiKey,
      useCustomPrompts: useCustomPrompts,
      customSystemPrompt: customSystemPrompt,
      customPlannerPrompt: customPlannerPrompt,
      customOperatorPrompt: customOperatorPrompt,
      customExplorePrompt: customExplorePrompt,
      customReviewerPrompt: customReviewerPrompt,
      customSummarizerPrompt: customSummarizerPrompt,
      customCoordinatorPrompt: customCoordinatorPrompt,
      apiFormat: apiFormat,
    );
  }

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    chatSaveAttempts += 1;
    if (failNextChatSave) {
      failNextChatSave = false;
      throw StateError(r'failed to write C:\private\active-chat.json');
    }
    await super.saveAiChat(chat);
  }
}
