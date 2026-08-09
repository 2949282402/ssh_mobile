import 'dart:async';
import '../../test_utils/ai_port_adapters.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/client_health_advisor.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<_PlanScreenHarness> createHarness(
    WidgetTester tester, {
    TestStorageAdapter? storageService,
  }) async {
    final harness = await tester.runAsync(
      () => _PlanScreenHarness.create(storageService: storageService),
    );
    if (harness == null) {
      throw StateError('Plan screen harness creation did not complete');
    }
    return harness;
  }

  void registerHarnessCleanup(WidgetTester tester, _PlanScreenHarness harness) {
    addTearDown(() async {
      await tester.runAsync(harness.dispose);
    });
  }

  testWidgets('missing API key opens LLM settings exactly once', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);
    final createdAt = DateTime.utc(2026, 7, 13, 12);
    final planChat = AiChatRecord(
      id: 'plan-chat',
      title: 'Plan chat',
      model: 'test-model',
      createdAt: createdAt,
      updatedAt: createdAt,
      messages: [
        AiChatMessageRecord(
          role: 'assistant',
          text: 'Review this plan.',
          createdAt: createdAt,
          todoSteps: const [
            AiTodoStep(
              id: 'step-1',
              name: 'Inspect nginx',
              command: 'systemctl status nginx',
              description: 'Read service status',
            ),
          ],
        ),
      ],
    );
    await tester.runAsync(() => harness.storageService.saveAiChat(planChat));
    final advisor = _HealthyAdvisor();

    await tester.pumpWidget(harness.app(advisor: advisor));
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    await tester.runAsync(viewModel.loadHistoryChatsIfNeeded);
    viewModel.selectChat(planChat.id);
    await tester.pumpAndSettle();

    final approve = find.byKey(
      ValueKey<String>('plan-approve-${createdAt.microsecondsSinceEpoch}'),
    );
    expect(approve, findsOneWidget);
    await tester.tap(approve);
    await tester.tap(approve, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(advisor.checkCount, 1);
    expect(find.byType(LlmSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('composer drafts are restored independently for each chat', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);
    final first = _historyChat('first-chat', DateTime.utc(2026, 7, 13, 12));
    final second = _historyChat('second-chat', DateTime.utc(2026, 7, 13, 11));
    await tester.runAsync(() async {
      await harness.storageService.saveAiChat(first);
      await harness.storageService.saveAiChat(second);
    });

    await tester.pumpWidget(harness.app(advisor: _HealthyAdvisor()));
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    await tester.runAsync(viewModel.loadHistoryChatsIfNeeded);
    viewModel.selectChat(first.id);
    await tester.pump();

    final input = find.byKey(const ValueKey<String>('chat-composer-input'));
    await tester.enterText(input, '/plan inspect first server');
    viewModel.selectChat(second.id);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);

    await tester.enterText(input, 'second chat draft');
    viewModel.selectChat(first.id);
    await tester.pump();
    expect(
      tester.widget<TextField>(input).controller!.text,
      '/plan inspect first server',
    );

    viewModel.selectChat(second.id);
    await tester.pump();
    expect(
      tester.widget<TextField>(input).controller!.text,
      'second chat draft',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('initial composer draft survives asynchronous chat bootstrap', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);

    await tester.pumpWidget(
      harness.app(
        advisor: _HealthyAdvisor(),
        initialText: 'keep this initial draft',
      ),
    );
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey<String>('chat-composer-input'));
    expect(
      tester.widget<TextField>(input).controller!.text,
      'keep this initial draft',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsent new-chat draft stays reachable and survives New chat', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);
    final history = _historyChat(
      'reachable-history',
      DateTime.utc(2026, 7, 13, 10),
    );
    await tester.runAsync(() => harness.storageService.saveAiChat(history));

    await tester.pumpWidget(harness.app(advisor: _HealthyAdvisor()));
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    await tester.runAsync(viewModel.loadHistoryChatsIfNeeded);
    final draft = viewModel.activeChat!;
    final input = find.byKey(const ValueKey<String>('chat-composer-input'));
    await tester.enterText(input, 'do not lose this draft');

    viewModel.selectChat(history.id);
    await tester.pump();
    final strings = AiStrings(harness.appSettings.language);
    await tester.tap(find.byTooltip(strings.newChat).first);
    await tester.pumpAndSettle();
    expect(viewModel.activeChatId, isNot(draft.id));
    expect(viewModel.chats.any((chat) => chat.id == draft.id), isTrue);

    await tester.tap(find.byTooltip(strings.history).first);
    await tester.pumpAndSettle();
    final savedDraft = find.byKey(ValueKey<String>('history-chat-${draft.id}'));
    expect(savedDraft, findsOneWidget);
    await tester.tap(savedDraft);
    await tester.pumpAndSettle();
    expect(viewModel.activeChatId, draft.id);
    expect(
      tester.widget<TextField>(input).controller!.text,
      'do not lose this draft',
    );

    await tester.runAsync(() => viewModel.deleteChat(draft.id));
    await tester.pump();
    expect(viewModel.activeChatId, isNot(draft.id));
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('New chat captures edits made while model settings load', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final storage = _GateNextSettingsLoadStorage();
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester, storageService: storage);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);

    await tester.pumpWidget(harness.app(advisor: _HealthyAdvisor()));
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    final originalChatId = viewModel.activeChatId!;
    final strings = AiStrings(harness.appSettings.language);
    final input = find.byKey(const ValueKey<String>('chat-composer-input'));
    storage.gateNextSettingsLoad();

    await tester.tap(find.byTooltip(strings.newChat).first);
    await tester.pump();
    await storage.nextSettingsLoadStarted;
    await tester.enterText(input, 'typed while model loads');
    storage.releaseSettingsLoad();
    await tester.pumpAndSettle();

    expect(viewModel.activeChatId, isNot(originalChatId));
    expect(viewModel.chats.any((chat) => chat.id == originalChatId), isTrue);
    viewModel.selectChat(originalChatId);
    await tester.pump();
    expect(
      tester.widget<TextField>(input).controller!.text,
      'typed while model loads',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale New chat request cannot replace a newer chat selection', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final storage = _GateNextSettingsLoadStorage();
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester, storageService: storage);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);

    await tester.pumpWidget(harness.app(advisor: _HealthyAdvisor()));
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    final originalChatId = viewModel.activeChatId!;
    viewModel.createChat('test-model', preserveChatIds: {originalChatId});
    final newerSelectionId = viewModel.activeChatId!;
    viewModel.selectChat(originalChatId);
    await tester.pump();
    final strings = AiStrings(harness.appSettings.language);
    storage.gateNextSettingsLoad();

    await tester.tap(find.byTooltip(strings.newChat).first);
    await tester.pump();
    await storage.nextSettingsLoadStarted;
    viewModel.selectChat(newerSelectionId);
    await tester.pump();
    storage.releaseSettingsLoad();
    await tester.pumpAndSettle();

    expect(viewModel.activeChatId, newerSelectionId);
    expect(viewModel.chats, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('New chat reports busy when a newer state write owns the lock', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final storage = _GateNextSettingsLoadStorage();
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester, storageService: storage);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);

    await tester.pumpWidget(harness.app(advisor: _HealthyAdvisor()));
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    final originalChat = viewModel.activeChat!;
    final strings = AiStrings(harness.appSettings.language);
    storage.gateNextSettingsLoad();

    await tester.tap(find.byTooltip(strings.newChat).first);
    await tester.pump();
    await storage.nextSettingsLoadStarted;
    storage.gateNextChatSave();
    late final Future<bool> stateWrite;
    await tester.runAsync(() async {
      stateWrite = viewModel.updateActiveChat(
        originalChat.copyWith(title: 'Updated while New chat loads'),
      );
      await storage.nextChatSaveStarted;
    });
    storage.releaseSettingsLoad();
    await tester.pumpAndSettle();

    expect(viewModel.activeChatId, originalChat.id);
    expect(find.text(strings.newChatBusy), findsOneWidget);
    storage.releaseChatSave();
    expect(await tester.runAsync(() => stateWrite), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp 2x Plan approval scales safely around its threshold', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);
    await tester.runAsync(harness.appSettings.toggleLanguage);
    final createdAt = DateTime.utc(2026, 7, 13, 14);
    await tester.runAsync(
      () => harness.storageService.saveAiChat(
        AiChatRecord(
          id: 'boundary-plan-chat',
          title: 'Boundary plan',
          model: 'test-model',
          createdAt: createdAt,
          updatedAt: createdAt,
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Boundary plan',
              createdAt: createdAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'boundary-step',
                  name: 'Inspect nginx',
                  command: 'systemctl status nginx',
                  description: 'Read service status',
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(
      harness.app(advisor: _HealthyAdvisor(), textScale: 2),
    );
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    await tester.runAsync(viewModel.loadHistoryChatsIfNeeded);
    viewModel.selectChat('boundary-plan-chat');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('plan-approval-area')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-composer-input')),
      '/',
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(960, 1380);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('plan-approval-area')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-composer-input')),
      '',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('plan-approval-area')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short 2x keyboard viewport does not overflow fixed Plan UI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1440);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final _PlanScreenHarness harness;
    try {
      harness = await createHarness(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    registerHarnessCleanup(tester, harness);
    final createdAt = DateTime.utc(2026, 7, 13, 13);
    await tester.runAsync(
      () => harness.storageService.saveAiChat(
        AiChatRecord(
          id: 'compact-plan-chat',
          title: 'Compact plan',
          model: 'test-model',
          createdAt: createdAt,
          updatedAt: createdAt,
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Compact plan',
              createdAt: createdAt,
              todoSteps: const [
                AiTodoStep(
                  id: 'compact-step',
                  name: 'Inspect nginx',
                  command: 'systemctl status nginx',
                  description: 'Read service status',
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(
      harness.app(advisor: _HealthyAdvisor(), textScale: 2, keyboardInset: 260),
    );
    await tester.pumpAndSettle();
    final viewModel = harness.viewModel!;
    await tester.runAsync(viewModel.loadHistoryChatsIfNeeded);
    viewModel.selectChat('compact-plan-chat');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('plan-approval-area')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-composer-input')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    expect(
      await tester.runAsync(
        () => viewModel.setPlanModeForActiveChat(
          chatId: 'compact-plan-chat',
          enabled: true,
        ),
      ),
      SetPlanModeResult.updated,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('plan-mode-banner')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

AiChatRecord _historyChat(String id, DateTime updatedAt) {
  return AiChatRecord(
    id: id,
    title: id,
    model: 'test-model',
    createdAt: updatedAt,
    updatedAt: updatedAt,
    messages: [
      AiChatMessageRecord(role: 'user', text: 'history', createdAt: updatedAt),
    ],
  );
}

class _HealthyAdvisor implements ClientHealthAdvisorAdapter {
  int checkCount = 0;

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) async {
    checkCount += 1;
    return const ClientRuntimeHealthReport(
      status: ClientRuntimeHealthStatus.ok,
      issues: [],
      raw: {},
    );
  }
}

class _PlanScreenHarness {
  final TestStorageAdapter storageService;
  final AppSettings appSettings;
  final SshService sshService;
  final SftpService sftpService;
  final PerformanceMonitorService performanceMonitorService;
  final PlaybookService playbookService;
  final RagService ragService;
  AiChatViewModel? viewModel;

  _PlanScreenHarness({
    required this.storageService,
    required this.appSettings,
    required this.sshService,
    required this.sftpService,
    required this.performanceMonitorService,
    required this.playbookService,
    required this.ragService,
  });

  static Future<_PlanScreenHarness> create({
    TestStorageAdapter? storageService,
  }) async {
    final resolvedStorageService = storageService ?? TestStorageAdapter();
    await resolvedStorageService.init();
    attachTestAiRepository(resolvedStorageService);
    final appSettings = AppSettings();
    await appSettings.init();
    final sshService = createTestSshService(resolvedStorageService);
    final sftpService = createTestSftpService(resolvedStorageService);
    final performanceMonitorService = createTestPerformanceMonitorService(
      sshService,
      resolvedStorageService,
    );
    final playbookService = PlaybookService(
      repository: resolvedStorageService.playbookRepository,
      sshService: sshService,
    );
    final ragService = RagService(aiStorage: resolvedStorageService.aiStorage);
    return _PlanScreenHarness(
      storageService: resolvedStorageService,
      appSettings: appSettings,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
    );
  }

  Widget app({
    required ClientHealthAdvisorAdapter advisor,
    String? initialText,
    double textScale = 1,
    double keyboardInset = 0,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<TestStorageAdapter>.value(value: storageService),
        Provider<ai.AiStoragePort>.value(value: aiStoragePort(storageService)),
        ChangeNotifierProvider<SshService>.value(value: sshService),
        Provider<ai.AiSshPort>.value(value: aiSshPort(sshService)),
        ChangeNotifierProvider<SftpService>.value(value: sftpService),
        Provider<ai.AiSftpPort>.value(value: aiSftpPort(sftpService)),
        ChangeNotifierProvider<PerformanceMonitorService>.value(
          value: performanceMonitorService,
        ),
        Provider<ai.AiMonitoringPort>.value(
          value: aiMonitoringPort(performanceMonitorService),
        ),
        ChangeNotifierProvider<PlaybookService>.value(value: playbookService),
        // 旧测试仍保留具体实现，同时按公开 Contract 注入 Playbook 能力。
        ListenableProvider<feature_playbook.PlaybookAutomationPort>.value(
          value: playbookService,
        ),
        ChangeNotifierProvider<RagService>.value(value: ragService),
        // 旧测试保留具体实现，同时按 RAG 公共 Contract 注入能力。
        ListenableProvider<feature_rag.RagCapability>.value(value: ragService),
        Provider<app_core.RagCapability>.value(
          value: aiRagCapability(ragService),
        ),
        ChangeNotifierProvider<AppSettings>.value(value: appSettings),
        ListenableProvider<ai.AiSettingsPort>.value(
          value: aiSettingsPort(appSettings),
        ),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: LlmChatScreen(
            initialText: initialText,
            viewModelFactory: (context) {
              return viewModel = createAiChatViewModel(
                storageService: storageService,
                sshService: sshService,
                sftpService: sftpService,
                performanceMonitorService: performanceMonitorService,
                playbookService: playbookService,
                ragService: ragService,
                appSettings: appSettings,
                clientHealthAdvisor: advisor,
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> dispose() async {
    ragService.dispose();
    playbookService.dispose();
    performanceMonitorService.dispose();
    sftpService.dispose();
    sshService.dispose();
    appSettings.dispose();
    await storageService.shutdown();
    storageService.dispose();
  }
}

class _GateNextSettingsLoadStorage extends TestStorageAdapter {
  Completer<void>? _settingsGate;
  Completer<void>? _settingsStarted;
  Completer<void>? _chatSaveGate;
  Completer<void>? _chatSaveStarted;

  Future<void> get nextSettingsLoadStarted => _settingsStarted!.future;
  Future<void> get nextChatSaveStarted => _chatSaveStarted!.future;

  void gateNextSettingsLoad() {
    _settingsGate = Completer<void>();
    _settingsStarted = Completer<void>();
  }

  void releaseSettingsLoad() => _settingsGate?.complete();

  void gateNextChatSave() {
    _chatSaveGate = Completer<void>();
    _chatSaveStarted = Completer<void>();
  }

  void releaseChatSave() => _chatSaveGate?.complete();

  @override
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    final gate = _settingsGate;
    if (gate != null) {
      _settingsStarted?.complete();
      await gate.future;
      _settingsGate = null;
    }
    return super.loadAiConnectionSettings();
  }

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    final gate = _chatSaveGate;
    if (gate != null) {
      _chatSaveStarted?.complete();
      await gate.future;
      _chatSaveGate = null;
    }
    return super.saveAiChat(chat);
  }
}
