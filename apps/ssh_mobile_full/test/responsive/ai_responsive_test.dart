import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_core/app_core.dart' as app_core;
import 'package:app_ui/app_ui.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

import '../test_utils/ai_port_adapters.dart';
import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;
  late AppSettings appSettings;
  late SshService sshService;
  late SftpService sftpService;
  late monitoring.MonitoringService performanceMonitorService;
  late feature_playbook.PlaybookService playbookService;
  late TestRagService ragService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = TestStorageAdapter();
    await storage.init();
    attachTestAiRepository(storage);
    installTestAiLogger();
    appSettings = AppSettings();
    await appSettings.init();
    sshService = createTestSshService(storage, appSettings: appSettings);
    sftpService = createTestSftpService(storage);
    performanceMonitorService = createTestPerformanceMonitorService(
      sshService,
      storage,
    );
    playbookService = createTestPlaybook(
      repository: storage.playbookRepository,
      sshService: sshService,
    );
    ragService = await createTestRagService(storage);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    playbookService.dispose();
    performanceMonitorService.dispose();
    sftpService.dispose();
    sshService.dispose();
    appSettings.dispose();
    await storage.shutdown();
    ragService.dispose();
    storage.dispose();
  });

  Future<void> pumpAi(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TestStorageAdapter>.value(value: storage),
          Provider<ai.AiStoragePort>.value(value: aiStoragePort(storage)),
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
          ChangeNotifierProvider<feature_playbook.PlaybookService>.value(
            value: playbookService,
          ),
          ListenableProvider<feature_playbook.PlaybookAutomationPort>.value(
            value: playbookService,
          ),
          ChangeNotifierProvider<TestRagService>.value(value: ragService),
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
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
          home: Scaffold(
            body: ai.LlmChatScreen(
              viewModelFactory: (context) {
                return createAiChatViewModel(
                  storageService: storage,
                  sshService: sshService,
                  sftpService: sftpService,
                  performanceMonitorService: performanceMonitorService,
                  playbookService: playbookService,
                  ragService: ragService,
                  appSettings: appSettings,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  group('AI Workspace Desktop Resolutions', () {
    const desktopResolutions = [
      Size(1280, 720),
      Size(1366, 768),
      Size(1920, 1080),
    ];

    for (final size in desktopResolutions) {
      testWidgets(
        'renders cleanly on ${size.width.toInt()}x${size.height.toInt()} desktop',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          try {
            await pumpAi(tester, size: size, platform: TargetPlatform.windows);

            expect(find.byType(ai.LlmChatScreen), findsOneWidget);
            expect(tester.takeException(), isNull);
          } finally {
            debugDefaultTargetPlatformOverride = null;
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        },
      );
    }
  });

  group('AI Workspace Mobile Resolutions', () {
    const mobileWidths = [320.0, 390.0, 430.0];

    for (final width in mobileWidths) {
      testWidgets('renders cleanly on ${width.toInt()}px mobile', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpAi(
            tester,
            size: Size(width, 800),
            platform: TargetPlatform.android,
          );

          expect(find.byType(ai.LlmChatScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      });
    }
  });
}
