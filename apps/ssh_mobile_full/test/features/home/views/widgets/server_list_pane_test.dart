import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_connection/feature_connection.dart' as feature;

import 'package:connection_core/connection_core.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/app/connection_runtime_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/app/terminal_feature_adapters.dart';
import 'package:ssh_mobile/app/terminal_ssh_capability_adapter.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../../../../test_utils/test_storage_adapter.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late TestStorageAdapter storageService;
  late _TestSshService sshService;
  late SftpService sftpService;
  late monitoring.MonitoringService performanceService;
  late feature.ConnectionViewModel connectionViewModel;
  late AppTerminalSettingsAdapter terminalSettings;
  late AppTerminalSshSessionManager terminalManager;
  late _UiConnectionAdapter connectionUiAdapter;

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
    sftpService = _UiSftpService();
    performanceService = createTestPerformanceMonitorService(
      sshService,
      storageService,
    );
    terminalSettings = AppTerminalSettingsAdapter(appSettings);
    terminalManager = AppTerminalSshSessionManager(sshService);
    connectionUiAdapter = _UiConnectionAdapter();
    connectionViewModel = feature.ConnectionViewModel(
      connectionRepository: storageService.connectionRepository,
      credentialRepository: storageService.credentialRepository,
      hostKeyRepository: storageService.hostKeyRepository,
      runtimePort: AppConnectionRuntimeAdapter(
        sshServiceFactory: () => sshService,
        sftpServiceFactory: () => sftpService,
        monitoringServiceFactory: () => performanceService,
      ),
      verificationPort: AppConnectionVerificationAdapter(
        credentialRepository: storageService.credentialRepository,
        hostKeyRepository: storageService.hostKeyRepository,
        logger: AppLogService.instance,
      ),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() async {
    connectionViewModel.dispose();
    await terminalManager.terminal.dispose();
    terminalSettings.dispose();
    performanceService.dispose();
    sftpService.dispose();
    sshService.dispose();
    await storageService.shutdown();
    storageService.dispose();
    appSettings.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Widget host({
    required ValueChanged<bool> onSettings,
    monitoring.MonitoringService? monitor,
  }) {
    final monitorForPage = monitor ?? performanceService;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider<feature.ConnectionViewModel>.value(
          value: connectionViewModel,
        ),
        ChangeNotifierProvider<SshService>.value(value: sshService),
        ChangeNotifierProvider.value(value: monitorForPage),
        Provider<ssh_core.SshSessionManager>.value(value: terminalManager),
        ListenableProvider<TerminalSettingsPort>.value(value: terminalSettings),
        Provider<feature.ConnectionUiAdapter>.value(value: connectionUiAdapter),
      ],
      child: MaterialApp(
        theme: AppTheme.lightThemeFor(),
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(body: Center(child: Text('route ${settings.name}'))),
          settings: settings,
        ),
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
        expect(padding.bottom, greaterThan(70));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'displays empty state when storage is ready and connections are empty',
    (tester) async {
      await tester.pumpWidget(host(onSettings: (_) {}));
      await tester.pumpAndSettle();

      expect(find.byType(AppSkeletonizer), findsNothing);
      expect(find.byType(AppEmptyState), findsOneWidget);
    },
  );

  testWidgets('displays skeleton during initial connection loading', (
    tester,
  ) async {
    final delayedRepo = _DelayedConnectionRepository();
    final loadingVm = feature.ConnectionViewModel(
      connectionRepository: delayedRepo,
      credentialRepository: storageService.credentialRepository,
      hostKeyRepository: storageService.hostKeyRepository,
      runtimePort: AppConnectionRuntimeAdapter(
        sshServiceFactory: () => sshService,
        sftpServiceFactory: () => sftpService,
        monitoringServiceFactory: () => performanceService,
      ),
      verificationPort: AppConnectionVerificationAdapter(
        credentialRepository: storageService.credentialRepository,
        hostKeyRepository: storageService.hostKeyRepository,
        logger: AppLogService.instance,
      ),
    );
    unawaited(loadingVm.fetchConnections());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(value: appSettings),
          ChangeNotifierProvider<SshService>.value(value: sshService),
          ChangeNotifierProvider<monitoring.MonitoringService>.value(
            value: performanceService,
          ),
          ChangeNotifierProvider<feature.ConnectionViewModel>.value(
            value: loadingVm,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
          home: const Scaffold(body: ServerListPane()),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AppSkeletonizer), findsOneWidget);
    expect(find.byType(AppEmptyState), findsNothing);

    delayedRepo.completer.complete([]);
    await tester.pumpAndSettle();
    expect(find.byType(AppSkeletonizer), findsNothing);
    expect(find.byType(AppEmptyState), findsOneWidget);
  });

  testWidgets(
    'retains real server cards and does not skeletonize when connections exist',
    (tester) async {
      await tester.runAsync(() async {
        await storageService.addConnection(
          ConnectionConfig(
            id: 'server-stale',
            name: 'Stale Server',
            host: '10.0.0.99',
            port: 22,
            username: 'deployment-user',
            authMethod: AuthMethod.password,
          ),
        );
        await connectionViewModel.fetchConnections();
      });
      await tester.pumpWidget(host(onSettings: (_) {}));
      await tester.pumpAndSettle();

      expect(find.text('Stale Server'), findsOneWidget);
      expect(find.byType(AppSkeletonizer), findsNothing);
    },
  );

  testWidgets(
    'desktop cards render health states, actions, and embedded windows',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final configs = <ConnectionConfig>[
        ConnectionConfig(
          id: 'healthy-server',
          name: 'Healthy server',
          host: 'healthy.example.test',
          username: 'operator',
        ),
        ConnectionConfig(
          id: 'warning-server',
          name: 'Warning server',
          host: 'warning.example.test',
          username: 'operator',
        ),
        ConnectionConfig(
          id: 'critical-server',
          name: 'Critical server',
          host: 'critical.example.test',
          username: 'operator',
        ),
        ConnectionConfig(
          id: 'unknown-server',
          name: 'Unknown server',
          host: 'unknown.example.test',
          username: 'operator',
        ),
      ];
      await tester.runAsync(() async {
        await appSettings.setServerListLayoutMode('grid');
        for (final config in configs) {
          await storageService.addConnection(config);
        }
        await connectionViewModel.fetchConnections();
      });
      sshService.setServerOverview(
        const SshServerOverviewSnapshot(
          byConnection: {
            'healthy-server': SshConnectionOverview(
              count: 2,
              latestState: SshConnectionState.connected,
              hasConnected: true,
            ),
            'warning-server': SshConnectionOverview(
              count: 1,
              latestState: SshConnectionState.connecting,
              hasConnected: false,
            ),
          },
          windowCount: 3,
        ),
      );
      final monitor = _UiMonitoringService({
        'healthy-server': _health(
          'healthy-server',
          monitoring.ServerHealthLevel.healthy,
          95,
          const ['CPU normal', 'Disk normal'],
        ),
        'warning-server': _health(
          'warning-server',
          monitoring.ServerHealthLevel.warning,
          50,
          const [],
        ),
        'critical-server': _health(
          'critical-server',
          monitoring.ServerHealthLevel.critical,
          20,
          const ['Disk full'],
        ),
      });

      await tester.pumpWidget(host(onSettings: (_) {}, monitor: monitor));
      await tester.pumpAndSettle();

      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Healthy server'), findsOneWidget);
      expect(find.text('Warning server'), findsOneWidget);
      expect(find.text('Critical server'), findsOneWidget);
      expect(find.text('Unknown server'), findsOneWidget);
      expect(find.text('Health 95 · CPU normal / Disk normal'), findsOneWidget);
      expect(find.text('Health 50 · Warning'), findsOneWidget);
      expect(find.text('Health 20 · Disk full'), findsOneWidget);
      expect(find.text('No monitoring data'), findsOneWidget);
      expect(find.text('2 windows'), findsOneWidget);

      final healthyCard = find.byKey(
        const ValueKey<String>('server-card-healthy-server'),
      );
      await tester.ensureVisible(healthyCard);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.moveTo(tester.getCenter(healthyCard));
      await tester.pump();
      await mouse.moveTo(const Offset(0, 0));
      await mouse.removePointer();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('route /edit'), findsOneWidget);
      Navigator.of(tester.element(find.text('route /edit'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(find.text('Delete connection'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      sshService.invokeUnknownHostKey = true;
      await tester.tap(
        find.byKey(const ValueKey<String>('server-card-healthy-server')),
      );
      await tester.pumpAndSettle();
      expect(find.text('route /terminal'), findsOneWidget);
      Navigator.of(tester.element(find.text('route /terminal'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New window').first);
      await tester.pumpAndSettle();
      expect(find.text('route /terminal'), findsOneWidget);
      Navigator.of(tester.element(find.text('route /terminal'))).pop();
      await tester.pumpAndSettle();

      await appSettings.setServerListLayoutMode('list');
      await tester.pumpAndSettle();
      final windowToggle = find.text('Window List · 2');
      expect(windowToggle, findsOneWidget);
      await tester.tap(windowToggle);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalWindowsPage), findsOneWidget);
      expect(find.text('No open terminal windows'), findsNothing);

      await tester.tap(windowToggle);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalWindowsPage), findsNothing);

      final unknownMenu = find.descendant(
        of: find.byKey(const ValueKey<String>('server-card-unknown-server')),
        matching: find.byIcon(Icons.more_vert),
      );
      await tester.ensureVisible(unknownMenu);
      await tester.tap(unknownMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Delete'),
        ),
      );
      await tester.pumpAndSettle();
      // The confirmation callback is asynchronous; a cleanup failure remains
      // visible on the VM instead of being mistaken for a successful delete.
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(connectionViewModel.errorMessage, isNull);
      expect(storageService.getConnection('unknown-server'), isNull);
      expect(find.text('Unknown server'), findsNothing);

      sshService.openSessionError = StateError('tmux is not installed');
      await tester.tap(
        find.byKey(const ValueKey<String>('server-card-warning-server')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Please install tmux manually'),
        findsOneWidget,
      );
      sshService.openSessionError = StateError('connection refused');
      await tester.tap(
        find.byKey(const ValueKey<String>('server-card-critical-server')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Connection failed:'), findsOneWidget);
      sshService.openSessionError = null;
      sshService.returnNullSession = true;
      await tester.tap(
        find.byKey(const ValueKey<String>('server-card-critical-server')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
    },
  );

  testWidgets(
    'desktop list supports reorder, selection, batch delete, and add route',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.runAsync(() async {
        await appSettings.setServerListLayoutMode('list');
        for (final id in ['first-server', 'second-server']) {
          await storageService.addConnection(
            ConnectionConfig(
              id: id,
              name: id,
              host: '$id.example.test',
              username: 'operator',
            ),
          );
        }
        await connectionViewModel.fetchConnections();
      });
      await tester.pumpWidget(host(onSettings: (_) {}));
      await tester.pumpAndSettle();

      expect(find.byType(ReorderableListView), findsOneWidget);
      final reorderable = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      await tester.runAsync(() async {
        reorderable.onReorderItem!(0, 1);
      });
      await tester.pumpAndSettle();
      expect(connectionViewModel.connections.first.id, 'second-server');

      await tester.tap(find.text('Add connection'));
      await tester.pumpAndSettle();
      expect(find.text('route /add'), findsOneWidget);
      Navigator.of(tester.element(find.text('route /add'))).pop();
      await tester.pumpAndSettle();

      final firstCard = find.byKey(
        const ValueKey<String>('server-card-second-server'),
      );
      await tester.longPress(firstCard);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(2));

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsNothing);

      await tester.longPress(
        find.byKey(const ValueKey<String>('server-card-second-server')),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('server-card-first-server')),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      final selectionDelete = find.widgetWithText(FilledButton, 'Delete');
      expect(selectionDelete, findsOneWidget);
      await tester.tap(selectionDelete);
      await tester.pumpAndSettle();
      expect(find.textContaining('Delete 2 selected servers?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(selectionDelete);
      await tester.pumpAndSettle();
      expect(find.textContaining('Delete 2 selected servers?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Delete'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.byType(AppEmptyState), findsOneWidget);

      expect(find.text('2 selected'), findsNothing);
    },
  );

  testWidgets('Chinese desktop header and batch confirmation stay localized', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await appSettings.toggleLanguage();
    await tester.runAsync(() async {
      await storageService.addConnection(
        ConnectionConfig(
          id: 'localized-server',
          name: '本地化服务器',
          host: 'localized.example.test',
          username: 'operator',
        ),
      );
      await connectionViewModel.fetchConnections();
    });
    await tester.pumpWidget(host(onSettings: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('已保存 1 台服务器'), findsOneWidget);
    final layoutButton = find.byTooltip('服务器列表布局');
    expect(layoutButton, findsOneWidget);
    await tester.tap(layoutButton);
    await tester.pumpAndSettle();
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('网格'), findsOneWidget);
    await tester.tap(find.text('网格'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);

    await tester.longPress(
      find.byKey(const ValueKey<String>('server-card-localized-server')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 台服务器'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除选中的 1 台服务器吗？'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '取消'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 台服务器'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 台服务器'), findsNothing);
  });
}

monitoring.ServerHealthSnapshot _health(
  String connectionId,
  monitoring.ServerHealthLevel level,
  int score,
  List<String> details,
) => monitoring.ServerHealthSnapshot(
  connectionId: connectionId,
  level: level,
  score: score,
  summary: level.name,
  details: details,
  updatedAt: DateTime.utc(2026, 1, 1),
);

final class _UiMonitoringService extends Fake
    implements monitoring.MonitoringService {
  _UiMonitoringService(this._healthByConnection);

  final Map<String, monitoring.ServerHealthSnapshot> _healthByConnection;

  @override
  bool isRunning = false;
  @override
  bool isSampling = false;
  @override
  Set<String> selectedConnectionIds = <String>{};
  @override
  Set<String> monitoringConnectionIds = <String>{};
  @override
  Duration interval = const Duration(seconds: 10);
  @override
  Duration historyWindow = const Duration(minutes: 5);
  @override
  Duration effectiveInterval = const Duration(seconds: 10);
  @override
  DateTime? startedAt;
  @override
  Map<String, String> errorsByConnection = const {};
  @override
  List<monitoring.MonitorAlert> alerts = const [];

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  monitoring.ServerHealthSnapshot healthFor(String connectionId) =>
      _healthByConnection[connectionId] ??
      _health(connectionId, monitoring.ServerHealthLevel.unknown, 0, const []);

  @override
  List<monitoring.PerformanceSample> visibleSamplesFor(String connectionId) =>
      const [];

  @override
  List<monitoring.PerformanceSample> samplesFor(String connectionId) =>
      const [];

  @override
  List<monitoring.DiskUsageSnapshot> diskUsageFor(String connectionId) =>
      const [];

  @override
  Future<void> startMonitoring({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    Map<String, ssh_core.SshTargetBinding>? targetBindings,
  }) async {}

  @override
  void stopMonitoring() {}

  @override
  void stopForConnection(String connectionId) {}

  @override
  Future<void> sampleNow({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {}

  @override
  void setInterval(Duration value) {}

  @override
  void setHistoryWindow(Duration value) {}

  @override
  void toggleSelection(String connectionId) {}

  @override
  void clearSelection() {}

  @override
  Future<List<monitoring.PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => const [];

  @override
  Future<List<monitoring.ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => const [];

  @override
  Future<List<monitoring.ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => const [];
}

final class _UiSftpService extends Fake implements SftpService {
  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) async {}

  @override
  void dispose() {}
}

final class _UiConnectionAdapter extends Fake
    implements feature.ConnectionUiAdapter {
  @override
  Future<bool> confirmHostKey(
    BuildContext context,
    feature.ConnectionHostKeyPrompt prompt,
  ) async => true;

  @override
  void logSaveFailure({
    required Object error,
    required StackTrace stackTrace,
    required ConnectionConfig? config,
  }) {}
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
  Object? openSessionError;
  bool invokeUnknownHostKey = false;
  bool returnNullSession = false;

  @override
  SshServerOverviewSnapshot get serverOverviewSnapshot => _overview;

  void setServerOverview(SshServerOverviewSnapshot value) {
    _overview = value;
    notifyListeners();
  }

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final error = openSessionError;
    if (error != null) throw error;
    if (invokeUnknownHostKey && onUnknownHostKey != null) {
      await onUnknownHostKey(
        ssh_core.SshHostKeyPromptRequest(
          connectionId: connectionId,
          connectionName: connectionId,
          host: '$connectionId.example.test',
          port: 22,
          username: 'operator',
          algorithm: 'ssh-ed25519',
          fingerprint: 'SHA256:test',
        ),
      );
    }
    if (returnNullSession) return null;
    return 'ui-session-$connectionId';
  }

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {}
}

class _DelayedConnectionRepository extends Fake
    implements ConnectionRepository {
  final Completer<List<ConnectionConfig>> completer =
      Completer<List<ConnectionConfig>>();

  @override
  List<ConnectionConfig> get connections => const [];

  @override
  Future<List<ConnectionConfig>> loadConnections() => completer.future;
}
