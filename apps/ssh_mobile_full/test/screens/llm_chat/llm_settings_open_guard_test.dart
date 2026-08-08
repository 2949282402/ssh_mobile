import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:feature_ai/ai_llm.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

import '../../test_utils/ai_port_adapters.dart';

Future<void> _pumpChatUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _waitForInitialChat(
  WidgetTester tester,
  AiChatViewModel viewModel,
) async {
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (!viewModel.loading && viewModel.activeChat != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pump();
}

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
    late final AppLogService logs;

    late final SshService ssh;
    late final SftpService sftp;
    late final PerformanceMonitorService monitor;
    late final PlaybookService playbooks;
    late final RagService rag;
    await tester.runAsync(() async {
      logs = AppLogService.instance;
      logs.clear();
      await storage.init();
      attachTestAiRepository(storage);
      await logs.detachDatabase(storage.appDatabase);
      await settings.init();
      await settings.toggleLanguage();
      ssh = SshService(storage);
      sftp = SftpService(storage);
      monitor = PerformanceMonitorService(ssh, storage);
      playbooks = PlaybookService(storageService: storage, sshService: ssh);
      rag = RagService(storageService: storage);
    });
    installTestAiLogger();
    addTearDown(logs.clear);

    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<StorageService>.value(value: storage),
            Provider<ai.AiStoragePort>.value(value: aiStoragePort(storage)),
            ChangeNotifierProvider<SshService>.value(value: ssh),
            Provider<ai.AiSshPort>.value(value: aiSshPort(ssh)),
            ChangeNotifierProvider<SftpService>.value(value: sftp),
            Provider<ai.AiSftpPort>.value(value: aiSftpPort(sftp)),
            ChangeNotifierProvider<PerformanceMonitorService>.value(
              value: monitor,
            ),
            Provider<ai.AiMonitoringPort>.value(
              value: aiMonitoringPort(monitor),
            ),
            ChangeNotifierProvider<PlaybookService>.value(value: playbooks),
            // 旧测试仍保留具体实现，同时按公开 Contract 注入 Playbook 能力。
            ListenableProvider<feature_playbook.PlaybookAutomationPort>.value(
              value: playbooks,
            ),
            ChangeNotifierProvider<RagService>.value(value: rag),
            // 旧测试保留具体实现，同时按 RAG 公共 Contract 注入能力。
            ListenableProvider<feature_rag.RagCapability>.value(value: rag),
            Provider<app_core.RagCapability>.value(value: aiRagCapability(rag)),
            ChangeNotifierProvider<AppSettings>.value(value: settings),
            ListenableProvider<ai.AiSettingsPort>.value(
              value: aiSettingsPort(settings),
            ),
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
      await _pumpChatUi(tester);
      final baselineLoads = storage.settingsLoads;
      final openSettings = find.byKey(const ValueKey('chat-open-llm-settings'));
      final openSettingsButton = find.byKey(
        const ValueKey('chat-open-llm-settings-button'),
      );
      expect(openSettings, findsOneWidget);
      expect(tester.getSize(openSettings).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(openSettings).width, greaterThanOrEqualTo(48));
      final viewModel = tester
          .element(openSettingsButton)
          .read<AiChatViewModel>();
      await _waitForInitialChat(tester, viewModel);

      final gate = storage.blockNextLoad();
      await tester.tap(openSettingsButton);
      await tester.tap(openSettingsButton);
      expect(storage.settingsLoads, baselineLoads + 1);
      await tester.pump();
      expect(tester.widget<IconButton>(openSettingsButton).onPressed, isNull);

      gate.complete();
      await _pumpChatUi(tester);
      expect(find.byType(LlmSettingsScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('llm-settings-close')));
      await _pumpChatUi(tester);
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
      await _pumpChatUi(tester);
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
      await _pumpChatUi(tester);
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
      await _pumpChatUi(tester);
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
      await _pumpChatUi(tester);
      expect(find.byType(LlmSettingsScreen), findsOneWidget);
      expect(storage.settingsLoads, baselineLoads + 5);
      await tester.tap(find.byKey(const ValueKey('llm-settings-close')));
      await _pumpChatUi(tester);

      logs.clear();
      final originalModel = viewModel.activeChat!.model;
      final baselineChatSaves = storage.chatSaveAttempts;
      storage.failNextChatSave = true;
      await tester.tap(openSettingsButton);
      await _pumpChatUi(tester);
      final modelField = find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButtonFormField<String> &&
            widget.decoration.labelText == 'Model',
      );
      expect(modelField, findsOneWidget);
      await tester.tap(modelField);
      await _pumpChatUi(tester);
      await tester.tap(find.text(_GuardedSettingsStorage.alternateModel).last);
      await _pumpChatUi(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _pumpChatUi(tester);
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
      await _pumpChatUi(tester);
      await tester.tap(openSettingsButton);
      await _pumpChatUi(tester);
      final baseUrlField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Base URL',
      );
      expect(baseUrlField, findsOneWidget);
      await tester.enterText(baseUrlField, 'https://api.retry.example/v1');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _pumpChatUi(tester);
      expect(find.byType(LlmSettingsScreen), findsNothing);
      expect(storage.chatSaveAttempts, baselineChatSaves + 2);
      expect(
        viewModel.activeChat!.model,
        _GuardedSettingsStorage.alternateModel,
      );

      logs.clear();
      await tester.tap(openSettingsButton);
      await _pumpChatUi(tester);
      await tester.enterText(
        baseUrlField,
        'https://private.example/v1?token=top-secret-value',
      );
      await tester.pump();
      storage.failNextSettingsSave = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _pumpChatUi(tester);
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
      await _pumpChatUi(tester);
      expect(find.byType(LlmSettingsScreen), findsNothing);

      logs.clear();
      const sensitiveSettingsValues = [
        'https://private-save.example/v1?token=endpoint-secret',
        'private-main-model',
        'private-helper-model',
        'private-audit-model',
        'https://private-quark.example/search?token=quark-secret',
      ];
      await tester.runAsync(() async {
        await storage.saveAiConnectionSettings(
          baseUrl: sensitiveSettingsValues[0],
          model: sensitiveSettingsValues[1],
          helperModel: sensitiveSettingsValues[2],
          auditModel: sensitiveSettingsValues[3],
          quarkSearchEndpoint: sensitiveSettingsValues[4],
          apiKey: 'valid-api-key-marker-for-log-test',
        );
      });
      final savedSettingsLog = logs.entries.singleWhere(
        (entry) => entry.message == 'LLM settings saved',
      );
      expect(savedSettingsLog.details, contains('hasBaseUrl=true'));
      expect(savedSettingsLog.details, contains('modelConfigured=true'));
      expect(savedSettingsLog.details, contains('helperModelConfigured=true'));
      expect(savedSettingsLog.details, contains('auditModelConfigured=true'));
      expect(
        savedSettingsLog.details,
        contains('quarkEndpointConfigured=true'),
      );
      final savedSettingsLogText = logs.entries
          .map((entry) => entry.text)
          .join('\n');
      for (final sensitiveFragment in [
        'private-save.example',
        'endpoint-secret',
        'private-main-model',
        'private-helper-model',
        'private-audit-model',
        'private-quark.example',
        'quark-secret',
        'valid-api-key-marker',
      ]) {
        expect(savedSettingsLogText, isNot(contains(sensitiveFragment)));
      }

      logs.clear();
      const rejectedBaseUrl =
          'https://private-rejected.example/v1?token=rejected-secret';
      const rejectedModel = 'private-rejected-model';
      await tester.runAsync(() async {
        await expectLater(
          storage.saveAiConnectionSettings(
            baseUrl: rejectedBaseUrl,
            model: rejectedModel,
            apiKey: 'invalid-key\nsecret',
          ),
          throwsA(isA<FormatException>()),
        );
      });
      final rejectedSettingsLog = logs.entries.singleWhere(
        (entry) => entry.message == 'LLM settings rejected invalid API key',
      );
      expect(rejectedSettingsLog.details, contains('hasBaseUrl=true'));
      expect(rejectedSettingsLog.details, contains('modelConfigured=true'));
      final rejectedSettingsLogText = logs.entries
          .map((entry) => entry.text)
          .join('\n');
      expect(
        rejectedSettingsLogText,
        isNot(contains('private-rejected.example')),
      );
      expect(rejectedSettingsLogText, isNot(contains('rejected-secret')));
      expect(rejectedSettingsLogText, isNot(contains(rejectedModel)));
      expect(rejectedSettingsLogText, isNot(contains('invalid-key')));

      final disposeGate = storage.blockNextLoad();
      await tester.tap(openSettingsButton);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      disposeGate.complete();
      await _pumpChatUi(tester);
      expect(tester.takeException(), isNull);
    } finally {
      storage.releasePendingLoads();
      await _pumpChatUi(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = originalPlatform;
      rag.dispose();
      playbooks.dispose();
      monitor.dispose();
      sftp.dispose();
      ssh.dispose();
      settings.dispose();
      await tester.runAsync(() async {
        await storage.shutdown();
      });
      storage.dispose();
    }
  });
}

class _GuardedSettingsStorage extends StorageService {
  static const alternateModel = 'settings-apply-test-model';

  _GuardedSettingsStorage() : super(databaseFactory: AppDatabase.forTesting);

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
