import 'package:flutter/foundation.dart';
import '../../../test_utils/ai_port_adapters.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/ai_tools.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late SshService sshService;
  late SftpService sftpService;
  late PerformanceMonitorService performanceMonitorService;
  late PlaybookService playbookService;
  late RagService ragService;
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
    playbookService = PlaybookService(
      repository: storageService.playbookRepository,
      sshService: sshService,
    );
    ragService = RagService(aiStorage: storageService.aiStorage);
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
