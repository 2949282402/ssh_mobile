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
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

import '../../test_utils/ai_port_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat bootstrap failure is safe and retryable on mobile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final storage = _FailOnceInitialSettingsStorage();
    final settings = AppSettings();
    await tester.runAsync(() async {
      await settings.init();
      await settings.toggleLanguage();
    });
    final ssh = SshService(storage);
    final sftp = SftpService(storage);
    final monitor = PerformanceMonitorService(ssh, storage);
    final playbooks = PlaybookService(storageService: storage, sshService: ssh);
    final rag = RagService(storageService: storage);

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
          child: const MaterialApp(home: LlmChatScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Unable to open AI chat'), findsOneWidget);
      expect(
        find.text('Failed to load chat settings. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining(r'C:\private\settings.db'), findsNothing);
      final retry = find.byKey(const ValueKey('chat-bootstrap-retry'));
      expect(retry, findsOneWidget);
      expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
      expect(storage.settingsLoadAttempts, 1);

      await tester.tap(retry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Unable to open AI chat'), findsNothing);
      expect(find.text('What can I help with?'), findsOneWidget);
      expect(storage.settingsLoadAttempts, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = originalPlatform;
      rag.dispose();
      playbooks.dispose();
      monitor.dispose();
      sftp.dispose();
      ssh.dispose();
      settings.dispose();
      await tester.runAsync(storage.shutdown);
      storage.dispose();
    }
  });
}

class _FailOnceInitialSettingsStorage extends StorageService {
  int settingsLoadAttempts = 0;
  static const _settings = AiConnectionSettings(
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
  );

  @override
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    settingsLoadAttempts += 1;
    if (settingsLoadAttempts == 1) {
      throw StateError(r'failed to read C:\private\settings.db');
    }
    return _settings;
  }

  @override
  Future<List<AiChatRecord>> loadAiChats() async => const [];
}
