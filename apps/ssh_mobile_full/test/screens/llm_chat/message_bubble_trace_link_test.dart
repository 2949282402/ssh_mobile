import 'package:feature_playbook/feature_playbook.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import '../../test_utils/test_storage_adapter.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;

import 'package:ssh_mobile/services/app_settings.dart';

import '../../test_utils/ai_port_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Trace link visibility under different message roles and runId states',
    (tester) async {
      final originalPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      final storageService = TestStorageAdapter();
      final appSettings = AppSettings();
      late final SshService sshService;
      late final SftpService sftpService;
      late final monitoring.MonitoringService performanceMonitorService;
      late final PlaybookService playbookService;
      late final TestRagService ragService;
      late final ai.AiDatabase aiDatabase;
      await tester.runAsync(() async {
        await storageService.init();
        aiDatabase = attachTestAiRepository(storageService);
        await appSettings.init();
        await appSettings.toggleLanguage();
        sshService = createTestSshService(storageService);
        sftpService = createTestSftpService(storageService);
        performanceMonitorService = createTestPerformanceMonitorService(
          sshService,
          storageService,
        );
        playbookService = createTestPlaybook(
          repository: storageService.playbookRepository,
          sshService: sshService,
        );
        ragService = await createTestRagService(storageService);
      });

      try {
        final testChat = AiChatRecord(
          id: 'test-chat-id',
          title: 'Test Chat',
          model: 'deepseek-v4-flash',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Assistant response with runId',
              createdAt: DateTime.now().subtract(const Duration(seconds: 4)),
              agentRunId: 'run-1',
              traces: const [],
            ),
            AiChatMessageRecord(
              role: 'error',
              text: 'Error response with runId',
              createdAt: DateTime.now().subtract(const Duration(seconds: 3)),
              agentRunId: 'run-2',
              traces: const [],
            ),
            AiChatMessageRecord(
              role: 'user',
              text: 'User prompt with runId',
              createdAt: DateTime.now().subtract(const Duration(seconds: 2)),
              agentRunId: 'run-3',
              traces: const [],
            ),
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Assistant response without runId',
              createdAt: DateTime.now().subtract(const Duration(seconds: 1)),
              agentRunId: null,
              traces: const [],
            ),
          ],
        );

        // Set active chat via storage
        await tester.runAsync(() async {
          await storageService.saveAiChat(testChat);
        });

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<TestStorageAdapter>.value(
                value: storageService,
              ),
              Provider<ai.AiStoragePort>.value(
                value: aiStoragePort(storageService),
              ),
              ChangeNotifierProvider<SshService>.value(value: sshService),
              Provider<ai.AiSshPort>.value(value: aiSshPort(sshService)),
              ChangeNotifierProvider<SftpService>.value(value: sftpService),
              Provider<ai.AiSftpPort>.value(value: aiSftpPort(sftpService)),
              ChangeNotifierProvider<monitoring.MonitoringService>.value(
                value: performanceMonitorService,
              ),
              Provider<ai.AiMonitoringPort>.value(
                value: aiMonitoringPort(performanceMonitorService),
              ),
              ChangeNotifierProvider<PlaybookService>.value(
                value: playbookService,
              ),
              // 旧测试仍保留具体实现，同时按公开 Contract 注入 Playbook 能力。
              ListenableProvider<feature_playbook.PlaybookAutomationPort>.value(
                value: playbookService,
              ),
              ChangeNotifierProvider<TestRagService>.value(value: ragService),
              // 旧测试保留具体实现，同时按 RAG 公共 Contract 注入能力。
              ListenableProvider<feature_rag.RagCapability>.value(
                value: ragService,
              ),
              Provider<app_core.RagCapability>.value(
                value: aiRagCapability(ragService),
              ),
              ChangeNotifierProvider<AppSettings>.value(value: appSettings),
              ListenableProvider<ai.AiSettingsPort>.value(
                value: aiSettingsPort(appSettings),
              ),
            ],
            child: const MaterialApp(home: Scaffold(body: LlmChatScreen())),
          ),
        );

        // Pump once to trigger initState and build loading state
        await tester.pump();

        // Retrieve the actual AiChatViewModel instance from the subtree context
        final context = tester.element(
          find
              .descendant(
                of: find.byType(LlmChatScreen),
                matching: find.byType(Scaffold),
              )
              .first,
        );
        final viewModel = Provider.of<AiChatViewModel>(context, listen: false);

        // Load history and select the chat
        await tester.runAsync(viewModel.loadHistoryChatsIfNeeded);
        viewModel.selectChat(testChat.id);

        // Pump and settle to let the chat messages render
        await tester.pumpAndSettle();

        // Verify Trace links:
        expect(find.textContaining('Trace · run-1'), findsOneWidget);
        expect(find.textContaining('Trace · run-2'), findsOneWidget);
        expect(find.textContaining('Trace · run-3'), findsNothing);

        // There shouldn't be a trace link containing 'Trace' for the assistant message without runId
        expect(find.textContaining('Trace · '), findsNWidgets(2));
        final traceLink = find
            .ancestor(
              of: find.textContaining('Trace · run-1'),
              matching: find.byType(InkWell),
            )
            .first;
        expect(tester.getSize(traceLink).height, greaterThanOrEqualTo(48));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = originalPlatform;
        playbookService.dispose();
        performanceMonitorService.dispose();
        sftpService.dispose();
        sshService.dispose();
        appSettings.dispose();
        await tester.runAsync(() async {
          await storageService.shutdown();
        });
        ragService.dispose();
        storageService.dispose();
        await tester.runAsync(aiDatabase.dispose);
      }
    },
  );
}
