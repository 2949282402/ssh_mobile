import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_connection/feature_connection.dart' as feature;

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/connection/viewmodels/connection_viewmodel.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../../../../test_utils/test_storage_adapter.dart';
import 'package:app_ui/app_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late TestStorageAdapter storageService;
  late _TestSshService sshService;
  late SftpService sftpService;
  late PerformanceMonitorService performanceService;
  late ConnectionViewModel connectionViewModel;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    appSettings = AppSettings();
    await appSettings.init();
    await appSettings.toggleLanguage();

    storageService = TestStorageAdapter();
    await storageService.init();
    sshService = _TestSshService(storageService);
    sftpService = createTestSftpService(storageService);
    performanceService = createTestPerformanceMonitorService(
      sshService,
      storageService,
    );
    connectionViewModel = ConnectionViewModel(
      connectionRepository: storageService.connectionRepository,
      credentialRepository: storageService.credentialRepository,
      hostKeyRepository: storageService.hostKeyRepository,
      sshService: sshService,
      sftpService: sftpService,
      performanceService: performanceService,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() async {
    connectionViewModel.dispose();
    performanceService.dispose();
    sftpService.dispose();
    sshService.dispose();
    await storageService.shutdown();
    storageService.dispose();
    appSettings.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Widget host({required ValueChanged<bool> onSettings}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider<feature.ConnectionViewModel>.value(
          value: connectionViewModel,
        ),
        ChangeNotifierProvider<SshService>.value(value: sshService),
        ChangeNotifierProvider.value(value: performanceService),
      ],
      child: MaterialApp(
        theme: AppTheme.lightThemeFor(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: NotificationListener<OpenSettingsNotification>(
            onNotification: (notification) {
              onSettings(true);
              return true;
            },
            child: const ServerListPane(),
          ),
        ),
      ),
    );
  }

  void usePortraitProfile(
    WidgetTester tester, {
    required Size physicalSize,
    required double devicePixelRatio,
  }) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('mobile header exposes a 48dp settings action', (tester) async {
    usePortraitProfile(
      tester,
      physicalSize: const Size(1440, 3120),
      devicePixelRatio: 3.5,
    );
    var settingsOpened = false;

    await tester.pumpWidget(
      host(onSettings: (value) => settingsOpened = value),
    );
    await tester.pump();

    final settings = find.byTooltip('Settings');
    expect(settings, findsOneWidget);
    expect(tester.getSize(settings), const Size(48, 48));

    await tester.tap(settings);
    await tester.pump();

    expect(settingsOpened, isTrue);
    expect(
      find.text('Add a connection to start a secure SSH session.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final profile in [
    (name: '1.5K', size: const Size(1280, 2856), dpr: 3.0),
    (name: '2K', size: const Size(1440, 3120), dpr: 3.5),
  ]) {
    testWidgets(
      '${profile.name} portrait grid preference safely falls back to a list',
      (tester) async {
        usePortraitProfile(
          tester,
          physicalSize: profile.size,
          devicePixelRatio: profile.dpr,
        );
        await tester.runAsync(() async {
          await appSettings.setServerListLayoutMode('grid');
          await storageService.addConnection(
            ConnectionConfig(
              id: 'server-1',
              name: 'Production gateway with a long server name',
              host: '2001:db8:85a3::8a2e:370:7334',
              port: 22,
              username: 'deployment-user',
              authMethod: AuthMethod.password,
            ),
          );
          await connectionViewModel.fetchConnections();
        });
        sshService.setServerOverview(
          const SshServerOverviewSnapshot(
            byConnection: {
              'server-1': SshConnectionOverview(
                count: 2,
                latestState: SshConnectionState.connected,
                hasConnected: true,
              ),
            },
            windowCount: 2,
          ),
        );

        await tester.pumpWidget(host(onSettings: (_) {}));
        await tester.pumpAndSettle();

        expect(find.byType(ReorderableListView), findsOneWidget);
        expect(find.byType(GridView), findsNothing);
        // Mobile list cards keep connection identity and actions visible while
        // omitting the low-value empty health row.
        expect(find.text('No monitoring data'), findsNothing);
        expect(find.textContaining('deployment-user@'), findsOneWidget);
        expect(find.textContaining('Health 0'), findsNothing);
        expect(find.text('Window List · 2'), findsOneWidget);

        final dragHandle = find.byKey(
          const ValueKey<String>('server-drag-handle-server-1'),
        );
        expect(tester.getSize(dragHandle), const Size(48, 48));

        final list = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );
        final padding = list.padding!;
        expect(padding.bottom, greaterThan(80));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _TestSshService extends SshService {
  _TestSshService(TestStorageAdapter storageService)
    : super(
        connectionRepository: storageService.connectionRepository,
        credentialRepository: storageService.credentialRepository,
        hostKeyRepository: storageService.hostKeyRepository,
        terminalMetadataStore: storageService.terminalMetadataStore,
      );

  SshServerOverviewSnapshot _overview = const SshServerOverviewSnapshot.empty();

  @override
  SshServerOverviewSnapshot get serverOverviewSnapshot => _overview;

  void setServerOverview(SshServerOverviewSnapshot value) {
    _overview = value;
    notifyListeners();
  }
}
