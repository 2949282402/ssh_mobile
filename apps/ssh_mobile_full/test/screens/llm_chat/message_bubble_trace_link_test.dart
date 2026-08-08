import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Trace link visibility under different message roles and runId states',
    (tester) async {
      final originalPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      final storageService = StorageService();
      final appSettings = AppSettings();
      late final SshService sshService;
      late final SftpService sftpService;
      late final PerformanceMonitorService performanceMonitorService;
      late final PlaybookService playbookService;
      late final RagService ragService;
      await tester.runAsync(() async {
        await storageService.init();
        await AppLogService.instance.detachDatabase(storageService.appDatabase);
        await appSettings.init();
        await appSettings.toggleLanguage();
        sshService = SshService(storageService);
        sftpService = SftpService(storageService);
        performanceMonitorService = PerformanceMonitorService(
          sshService,
          storageService,
        );
        playbookService = PlaybookService(
          storageService: storageService,
          sshService: sshService,
        );
        ragService = RagService(storageService: storageService);
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
              ChangeNotifierProvider<StorageService>.value(
                value: storageService,
              ),
              ChangeNotifierProvider<SshService>.value(value: sshService),
              ChangeNotifierProvider<SftpService>.value(value: sftpService),
              ChangeNotifierProvider<PerformanceMonitorService>.value(
                value: performanceMonitorService,
              ),
              ChangeNotifierProvider<PlaybookService>.value(
                value: playbookService,
              ),
              // 旧测试仍保留具体实现，同时按公开 Contract 注入 Playbook 能力。
              ListenableProvider<feature_playbook.PlaybookAutomationPort>.value(
                value: playbookService,
              ),
              ChangeNotifierProvider<RagService>.value(value: ragService),
              ChangeNotifierProvider<AppSettings>.value(value: appSettings),
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
        ragService.dispose();
        playbookService.dispose();
        performanceMonitorService.dispose();
        sftpService.dispose();
        sshService.dispose();
        appSettings.dispose();
        await tester.runAsync(() async {
          await storageService.shutdown();
        });
        storageService.dispose();
      }
    },
  );
}
