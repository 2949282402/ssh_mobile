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

  group('Terminal Workspace Desktop Resolutions', () {
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
            await pumpTerminal(
              tester,
              size: size,
              platform: TargetPlatform.windows,
            );

            expect(find.byType(AppEmptyState), findsOneWidget);
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

  group('Terminal Workspace Mobile Resolutions', () {
    const mobileWidths = [320.0, 390.0, 430.0];

    for (final width in mobileWidths) {
      testWidgets('renders cleanly on ${width.toInt()}px mobile', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpTerminal(
            tester,
            size: Size(width, 800),
            platform: TargetPlatform.android,
          );

          expect(find.byType(AppEmptyState), findsOneWidget);
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
