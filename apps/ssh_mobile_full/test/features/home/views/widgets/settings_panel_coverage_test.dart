import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_connection/feature_connection.dart' as feature;
import 'package:feature_developer/feature_developer.dart' as developer;
import 'package:ssh_mobile/app/connection_runtime_adapters.dart';
import 'package:ssh_mobile/app/developer_feature_adapters.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:app_ui/app_ui.dart';

import '../../../../test_utils/test_storage_adapter.dart';
import '../../../../test_utils/ai_port_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;
  late AppSettings appSettings;
  late SettingsViewModel settingsViewModel;
  late SshService sshService;
  late feature.ConnectionViewModel connectionViewModel;
  late AppDeveloperLogAdapter developerLogAdapter;
  late AppDeveloperSettingsAdapter developerSettingsAdapter;
  late _FakeDeveloperDiagnostics developerDiagnostics;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = TestStorageAdapter();
    await storage.init();
    attachTestAiRepository(storage);
    appSettings = AppSettings();
    await appSettings.init();
    await appSettings.toggleLanguage();
    settingsViewModel = SettingsViewModel(
      appSettings: appSettings,
      aiStorage: storage.aiStorage,
    );
    sshService = createTestSshService(storage, appSettings: appSettings);
    developerLogAdapter = AppDeveloperLogAdapter(AppLogService.instance);
    developerSettingsAdapter = AppDeveloperSettingsAdapter(appSettings);
    developerDiagnostics = _FakeDeveloperDiagnostics();
    connectionViewModel = feature.ConnectionViewModel(
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
    );
  });

  tearDown(() async {
    connectionViewModel.dispose();
    settingsViewModel.dispose();
    sshService.dispose();
    developerLogAdapter.dispose();
    developerSettingsAdapter.dispose();
    developerDiagnostics.dispose();
    await storage.shutdown();
    storage.dispose();
    appSettings.dispose();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(value: appSettings),
          ChangeNotifierProvider<SettingsViewModel>.value(
            value: settingsViewModel,
          ),
          ChangeNotifierProvider<feature.ConnectionViewModel>.value(
            value: connectionViewModel,
          ),
          ChangeNotifierProvider<SshService>.value(value: sshService),
          ListenableProvider<developer.DeveloperLogPort>.value(
            value: developerLogAdapter,
          ),
          ListenableProvider<developer.DeveloperSettingsPort>.value(
            value: developerSettingsAdapter,
          ),
          ListenableProvider<developer.DeveloperDiagnosticsPort>.value(
            value: developerDiagnostics,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
  }

  testWidgets(
    'settings panel drives appearance, security, backup, and developer state',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpHome(tester);
      await openSettings(tester);

      expect(find.text('Language'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Switch to dark mode'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('app-color-palette-selector')),
        findsOneWidget,
      );

      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      expect(appSettings.language, AppLanguage.zh);
      expect(find.text('语言'), findsOneWidget);

      // Switch back to English so the remaining assertions exercise the same
      // labels while still covering the language toggle in both directions.
      await tester.tap(find.text('语言'));
      await tester.pumpAndSettle();
      expect(appSettings.language, AppLanguage.en);

      await tester.tap(find.text('Switch to dark mode'));
      await tester.pumpAndSettle();
      expect(appSettings.isDarkMode, isTrue);
      expect(find.text('OLED Black Mode'), findsOneWidget);

      final paletteSelector = find.byKey(
        const ValueKey('app-color-palette-selector'),
      );
      await tester.drag(paletteSelector, const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-color-palette-amber')));
      await tester.pumpAndSettle();
      expect(appSettings.colorPalette, AppColorPalette.amber);

      await tester.tap(find.text('OLED Black Mode'));
      await tester.pumpAndSettle();
      expect(appSettings.oledDark, isTrue);

      final cacheSwitch = find.widgetWithText(
        SwitchListTile,
        'Cache SSH credentials',
      );
      expect(cacheSwitch, findsOneWidget);
      expect(settingsViewModel.secretCacheEnabled, isTrue);
      await tester.tap(cacheSwitch);
      await tester.pumpAndSettle();
      expect(settingsViewModel.secretCacheEnabled, isFalse);
      await tester.tap(cacheSwitch);
      await tester.pumpAndSettle();
      expect(settingsViewModel.secretCacheEnabled, isTrue);

      final cacheDropdown = find.byType(DropdownButton<int>);
      expect(cacheDropdown, findsOneWidget);
      final settingsList = find.byType(ListView);
      expect(settingsList, findsOneWidget);
      await tester.drag(settingsList, const Offset(0, -420));
      await tester.pumpAndSettle();
      await tester.tap(cacheDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('15m').last);
      await tester.pumpAndSettle();
      expect(settingsViewModel.secretCacheTtlMinutes, 15);

      final notificationSwitch = find.widgetWithText(
        SwitchListTile,
        'Show server names in background notifications',
      );
      expect(notificationSwitch, findsOneWidget);
      await tester.tap(notificationSwitch);
      await tester.pumpAndSettle();
      expect(appSettings.showServerNamesInNotifications, isTrue);

      await tester.drag(settingsList, const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Developer Mode'));
      await tester.pumpAndSettle();
      expect(appSettings.developerMode, isTrue);
      expect(find.text('Developer Panel'), findsOneWidget);
      expect(find.text('Developer logs'), findsOneWidget);

      await tester.drag(settingsList, const Offset(0, -1000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Developer Panel'));
      await tester.pumpAndSettle();
      expect(find.byType(developer.DeveloperPanelScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Developer logs'));
      await tester.pumpAndSettle();
      expect(find.byType(developer.DeveloperLogPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _FakeDeveloperDiagnostics extends ChangeNotifier
    implements developer.DeveloperDiagnosticsPort {
  @override
  List<developer.DeveloperComponentStatus> get componentStatuses => const [];

  @override
  developer.DeveloperDiagnosticsSnapshot get snapshot =>
      developer.DeveloperDiagnosticsSnapshot(
        capturedAt: DateTime(2024),
        modules: const [],
        ssh: const developer.DeveloperSshSnapshot(
          activeSessions: 0,
          idleSessions: 0,
          leaseCount: 0,
        ),
        network: const developer.DeveloperNetworkSnapshot(
          activeConnections: 0,
          nativeHandles: 0,
        ),
        databases: const [],
        resources: const developer.DeveloperResourceSnapshot(
          activeTimers: 0,
          activeSubscriptions: 0,
        ),
      );

  @override
  Future<developer.DeveloperNativeMemorySnapshot?> readNativeMemory() async =>
      null;

  @override
  Future<int> replayTelemetry() async => 0;

  @override
  Future<int> retryRejectedTelemetry() async => 0;

  @override
  Future<void> flushTelemetry() async {}

  @override
  Future<bool> refreshTelemetryPolicy() async => false;
}
