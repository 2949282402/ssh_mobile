import 'package:feature_playbook/feature_playbook.dart';
import 'package:flutter/foundation.dart';
import '../../../test_utils/ai_port_adapters.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/ai_tools.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;

import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late SshService sshService;
  late SftpService sftpService;
  late monitoring.MonitoringService performanceMonitorService;
  late PlaybookService playbookService;
  late TestRagService ragService;
  late AppSettings appSettings;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = TestStorageAdapter();
    await storageService.init();

    appSettings = AppSettings();
    await appSettings.init();

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

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('AiChatRuntimeFactory Tests', () {
    test('creates ChatOrchestrator correctly', () {
      final factory = createAiChatRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final orchestrator = factory.createOrchestrator();
      expect(orchestrator, isA<ChatOrchestrator>());
    });

    test('creates AiToolService correctly', () {
      final factory = createAiChatRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final toolService = factory.createToolService(chatId: 'test-chat-id');
      expect(toolService, isA<AiToolService>());
      expect(toolService.clientWebViewSessionId, 'test-chat-id');
    });

    test('creates LlmChatService correctly', () async {
      final factory = createAiChatRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final settings = await storageService.loadAiConnectionSettings();

      final llmService = factory.createLlmChatService(
        settings: settings,
        model: 'gpt-4o',
        chatId: 'test-chat-id',
        language: AppLanguage.zh,
      );

      expect(llmService, isA<LlmChatService>());
    });
  });
}
