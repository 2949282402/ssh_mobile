import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_ui/app_ui.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:ssh_mobile/app/connection_route_scope.dart';
import 'package:ssh_mobile/app/connection_runtime_adapters.dart';
import 'package:ssh_mobile/app/terminal_feature_adapters.dart';
import 'package:ssh_mobile/app/terminal_ssh_capability_adapter.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/shortcut_command_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

import '../app/support/ssh_terminal_test_fakes.dart';
import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;
  late AppSettings appSettings;
  late SshService sshService;
  late ShortcutCommandService shortcutService;
  late FakeTerminalHistoryRepository historyRepository;
  late GlobalKey<NavigatorState> navigatorKey;
  late AppTerminalSshSessionManager sessionManager;

  setUp(() async {
    Provider.debugCheckInvalidValueType = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = TestStorageAdapter();
    await storage.init();
    appSettings = AppSettings();
    await appSettings.init();
    sshService = createTestSshService(storage, appSettings: appSettings);
    shortcutService = ShortcutCommandService();
    historyRepository = FakeTerminalHistoryRepository();
    navigatorKey = GlobalKey<NavigatorState>();
    sessionManager = AppTerminalSshSessionManager(sshService);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await sessionManager.terminal.dispose();
    shortcutService.dispose();
    sshService.dispose();
    await storage.shutdown();
    storage.dispose();
    appSettings.dispose();
  });

  Future<void> pumpTerminal(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;

    final settingsAdapter = AppTerminalSettingsAdapter(appSettings);
    final shortcutAdapter = AppTerminalShortcutAdapter(shortcutService);
    final connectionAdapter = AppTerminalConnectionAdapter(
      navigatorKey: navigatorKey,
      connectionRepository: storage.connectionRepository,
      sshService: sshService,
    );
    final loggerAdapter = AppTerminalLoggerAdapter(AppLogService.instance);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(value: appSettings),
          ChangeNotifierProvider<SshService>.value(value: sshService),
          Provider<TerminalHistoryRepository>.value(value: historyRepository),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: AppTheme.lightThemeFor(),
          home: AppConnectionRouteScope(
            connectionRepository: storage.connectionRepository,
            credentialRepository: storage.credentialRepository,
            hostKeyRepository: storage.hostKeyRepository,
            runtimePort: AppConnectionRuntimeAdapter(
              sshServiceFactory: () => sshService,
            ),
            verificationPort: AppConnectionVerificationAdapter(
              credentialRepository: storage.credentialRepository,
              hostKeyRepository: storage.hostKeyRepository,
              logger: AppLogService.instance,
            ),
            child: TerminalFeatureScope(
              sshSessionManager: sessionManager,
              settings: settingsAdapter,
              shortcuts: shortcutAdapter,
              connections: connectionAdapter,
              logger: loggerAdapter,
              historyRepository: historyRepository,
              child: const Scaffold(body: TerminalWindowsPage()),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }

  testWidgets('Terminal workspace golden - Desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpTerminal(
        tester,
        size: const Size(1280, 720),
        platform: TargetPlatform.windows,
      );

      expect(find.byType(TerminalWindowsPage), findsOneWidget);
      await expectLater(
        find.byType(TerminalWindowsPage),
        matchesGoldenFile('goldens/terminal_desktop.png'),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('Terminal workspace golden - Mobile', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpTerminal(
        tester,
        size: const Size(390, 800),
        platform: TargetPlatform.android,
      );

      expect(find.byType(TerminalWindowsPage), findsOneWidget);
      await expectLater(
        find.byType(TerminalWindowsPage),
        matchesGoldenFile('goldens/terminal_mobile.png'),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
