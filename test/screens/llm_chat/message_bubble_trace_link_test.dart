import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/screens/llm_chat_screen.dart';
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
    await storageService.init();

    final appSettings = AppSettings();
    await appSettings.init();

    final sshService = SshService(storageService);
    final sftpService = SftpService(storageService);
    final performanceMonitorService =
        PerformanceMonitorService(sshService, storageService);
    final playbookService =
        PlaybookService(storageService: storageService, sshService: sshService);
    final ragService = RagService(storageService: storageService);

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
      await storageService.saveAiChat(testChat);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<StorageService>.value(value: storageService),
            ChangeNotifierProvider<SshService>.value(value: sshService),
            ChangeNotifierProvider<SftpService>.value(value: sftpService),
            ChangeNotifierProvider<PerformanceMonitorService>.value(
                value: performanceMonitorService),
            ChangeNotifierProvider<PlaybookService>.value(
                value: playbookService),
            ChangeNotifierProvider<RagService>.value(value: ragService),
            ChangeNotifierProvider<AppSettings>.value(value: appSettings),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: LlmChatScreen(),
            ),
          ),
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
      await viewModel.loadHistoryChatsIfNeeded();
      viewModel.selectChat(testChat.id);

      // Pump and settle to let the chat messages render
      await tester.pumpAndSettle();

      // Verify Trace links:
      expect(find.textContaining('Trace · run-1'), findsOneWidget);
      expect(find.textContaining('Trace · run-2'), findsOneWidget);
      expect(find.textContaining('Trace · run-3'), findsNothing);

      // There shouldn't be a trace link containing 'Trace' for the assistant message without runId
      expect(find.textContaining('Trace · '), findsNWidgets(2));
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
      storageService.dispose();
    }
  });
}
