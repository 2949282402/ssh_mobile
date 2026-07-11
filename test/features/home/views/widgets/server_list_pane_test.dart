import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/connection/viewmodels/connection_viewmodel.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/utils/responsive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late StorageService storageService;
  late SshService sshService;
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

    storageService = StorageService();
    await storageService.init();
    sshService = SshService(storageService);
    sftpService = SftpService(storageService);
    performanceService = PerformanceMonitorService(sshService, storageService);
    connectionViewModel = ConnectionViewModel(
      connectionRepository: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceService: performanceService,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() {
    connectionViewModel.dispose();
    performanceService.dispose();
    sftpService.dispose();
    sshService.dispose();
    storageService.dispose();
    appSettings.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Widget host({required ValueChanged<bool> onSettings}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: connectionViewModel),
        ChangeNotifierProvider.value(value: sshService),
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

        await tester.pumpWidget(host(onSettings: (_) {}));
        await tester.pumpAndSettle();

        expect(find.byType(ReorderableListView), findsOneWidget);
        expect(find.byType(GridView), findsNothing);
        expect(find.text('No monitoring data'), findsOneWidget);
        expect(find.textContaining('Health 0'), findsNothing);

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
