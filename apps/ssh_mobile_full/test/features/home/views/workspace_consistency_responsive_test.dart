import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_ui/app_ui.dart';
import 'package:ssh_mobile/app/connection_route_scope.dart';
import 'package:ssh_mobile/app/connection_runtime_adapters.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

import '../../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;
  late AppSettings appSettings;
  late SettingsViewModel settingsViewModel;
  late SshService sshService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = TestStorageAdapter();
    await storage.init();
    appSettings = AppSettings();
    await appSettings.init();
    settingsViewModel = SettingsViewModel(
      appSettings: appSettings,
      aiStorage: storage.aiStorage,
    );
    sshService = createTestSshService(storage, appSettings: appSettings);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    settingsViewModel.dispose();
    sshService.dispose();
    await storage.shutdown();
    storage.dispose();
    appSettings.dispose();
  });

  Future<void> pumpWorkspace(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
    int initialIndex = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(value: appSettings),
          ChangeNotifierProvider<SettingsViewModel>.value(
            value: settingsViewModel,
          ),
          ChangeNotifierProvider<SshService>.value(value: sshService),
        ],
        child: MaterialApp(
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
            child: HomeScreen(initialIndex: initialIndex),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }

  group('Desktop Multi-Window Resolutions', () {
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
            await pumpWorkspace(
              tester,
              size: size,
              platform: TargetPlatform.windows,
              initialIndex: 0,
            );

            // Navigation rail is visible
            expect(find.byType(NavigationRail), findsOneWidget);
            // Page surface is present
            expect(find.byType(AppPageSurface), findsWidgets);
            // No overflow errors
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

  group('Mobile Resolutions & Touch Target Compliance', () {
    const mobileWidths = [320.0, 390.0, 430.0];

    for (final width in mobileWidths) {
      testWidgets(
        'renders cleanly and maintains touch targets on ${width.toInt()}px mobile',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          try {
            await pumpWorkspace(
              tester,
              size: Size(width, 800),
              platform: TargetPlatform.android,
              initialIndex: 0,
            );

            // Bottom navigation is visible
            final homeNav = find.byKey(const ValueKey('home-nav-0'));
            expect(homeNav, findsOneWidget);

            final navSize = tester.getSize(homeNav);
            expect(navSize.height, greaterThanOrEqualTo(44.0));

            // No overflow errors
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
}
