import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/system_admin/views/system_admin_screen.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart';
import 'package:ssh_mobile/features/system_admin/viewmodels/system_admin_viewmodel.dart';
import 'package:ssh_mobile/widgets/system_power_confirm_flow.dart';
import 'package:ssh_mobile/features/performance/viewmodels/performance_viewmodel.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/models/system_admin.dart';
import 'package:ssh_mobile/services/server_status_probe.dart';

class StubSystemAdminViewModel extends ChangeNotifier
    implements SystemAdminViewModel {
  @override
  String? selectedConnectionId;

  @override
  String? managementConnectionId;

  @override
  bool isConnected = false;

  @override
  bool isConnecting = false;

  @override
  bool isRoot = false;

  @override
  String? errorMessage;

  @override
  bool storageInitialized = true;

  @override
  bool serversCollapsed = false;

  @override
  List<LinuxUserAccount> accounts = [];

  @override
  bool loadingAccounts = false;

  @override
  List<ActiveSession> sessions = [];

  @override
  bool loadingSessions = false;

  @override
  List<SystemdService> services = [];

  @override
  bool loadingServices = false;

  @override
  List<ListeningPort> ports = [];

  @override
  bool loadingPorts = false;

  @override
  List<ConnectionConfig> connections = [];

  int connectIfNeededCalls = 0;
  final List<String> fetchAccountsCalls = [];
  final List<String> fetchSessionsCalls = [];
  final List<String> fetchServicesCalls = [];
  final List<String> fetchPortsCalls = [];
  bool populateServicesOnFetch = false;
  bool connectOnDemand = true;

  @override
  String? get connectionId => selectedConnectionId;

  @override
  String? get activeManagementConnectionId {
    final id = managementConnectionId;
    if (id == null || id != selectedConnectionId) return null;
    return id;
  }

  @override
  bool get canManageSelectedConnection {
    return activeManagementConnectionId != null && isConnected && isRoot;
  }

  @override
  bool get isConnectingSelectedConnection {
    return managementConnectionId == selectedConnectionId && isConnecting;
  }

  @override
  bool get isConnectedSelectedConnection {
    return managementConnectionId == selectedConnectionId && isConnected;
  }

  @override
  bool get hasManagementErrorForSelectedConnection {
    return managementConnectionId == selectedConnectionId &&
        errorMessage != null;
  }

  @override
  ConnectionConfig? get selectedConnection =>
      connectionById(selectedConnectionId);

  @override
  bool get hasValidSelection =>
      selectedConnectionId != null && selectedConnection != null;

  @override
  void cancelActiveCommands() {}

  @override
  Duration debounceDuration = Duration.zero;

  @override
  ConnectionConfig? connectionById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final connection in connections) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  @override
  bool isConnectingConnection(String id) {
    return managementConnectionId == id && isConnecting;
  }

  @override
  void selectConnection(String id) {
    selectedConnectionId = id;
    accounts = [];
    sessions = [];
    services = [];
    ports = [];
    notifyListeners();
  }

  @override
  Future<void> connect(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    managementConnectionId = id;
    isConnected = true;
    isRoot = true;
    notifyListeners();
  }

  @override
  Future<void> connectIfNeeded(
    String id, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (selectedConnectionId != id) return;
    if (canManageSelectedConnection) return;
    connectIfNeededCalls++;
    if (!connectOnDemand) return;
    await connect(id, onUnknownHostKey: onUnknownHostKey);
  }

  @override
  void disconnect() {
    managementConnectionId = null;
    isConnected = false;
    isRoot = false;
    notifyListeners();
  }

  @override
  void restoreServersCollapsed(BuildContext context) {}

  @override
  void setServersCollapsed(BuildContext context, bool collapsed) {
    serversCollapsed = collapsed;
    notifyListeners();
  }

  @override
  void clearInvalidSelection() {
    final id = selectedConnectionId;
    if (id == null) return;
    selectedConnectionId = null;
    accounts = [];
    sessions = [];
    services = [];
    ports = [];
    if (managementConnectionId == id) {
      disconnect();
      return;
    }
    notifyListeners();
  }

  @override
  void validateSelectedConnection() {
    if (selectedConnectionId != null &&
        connectionById(selectedConnectionId) == null) {
      clearInvalidSelection();
    }
  }

  @override
  Future<void> refreshAllData() async {}

  @override
  Future<void> fetchAccounts(String connId, {bool force = false}) async {
    fetchAccountsCalls.add(connId);
  }

  @override
  Future<void> fetchSessions(String connId, {bool force = false}) async {
    fetchSessionsCalls.add(connId);
  }

  @override
  Future<void> fetchServices(String connId, {bool force = false}) async {
    fetchServicesCalls.add(connId);
    if (populateServicesOnFetch) {
      services = [
        SystemdService(
          name: 'nginx.service',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          description: 'Nginx Service',
        ),
        SystemdService(
          name: 'ssh.service',
          loadState: 'loaded',
          activeState: 'inactive',
          subState: 'dead',
          description: 'OpenSSH Server',
        ),
      ];
      notifyListeners();
    }
  }

  @override
  Future<void> fetchPorts(String connId, {bool force = false}) async {
    fetchPortsCalls.add(connId);
  }

  @override
  Future<void> createUser(
    String username,
    String password, {
    String shell = '/bin/bash',
  }) async {}

  @override
  Future<bool> checkUserSudo(String username) async => false;

  @override
  Future<void> setUserSudo(String username, bool grant) async {}

  @override
  Future<void> lockUser(String username) async {}

  @override
  Future<void> unlockUser(String username) async {}

  @override
  Future<void> changePassword(String username, String newPassword) async {}

  @override
  Future<String> getUserHomeStorageUsage(String homeDir) async => 'N/A';

  @override
  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(
    String username,
  ) async => [];

  @override
  Future<void> killActiveSession(String tty) async {}

  @override
  Future<void> manageSystemdService(String serviceName, String action) async {}

  @override
  Future<void> rebootServer(SystemPowerConfirmationToken token) async {}

  @override
  Future<void> shutdownServer(SystemPowerConfirmationToken token) async {}
}

class StubPerformanceMonitorViewModel extends ChangeNotifier
    implements PerformanceMonitorViewModel {
  @override
  int activeTabIndex = 0;

  @override
  bool serversCollapsed = false;

  @override
  String? activeConnectionId;

  @override
  bool isRunning = false;

  @override
  bool isSampling = false;

  @override
  Set<String> selectedConnectionIds = {};

  @override
  Set<String> monitoringConnectionIds = {};

  @override
  Duration interval = const Duration(seconds: 5);

  @override
  Duration historyWindow = const Duration(minutes: 5);

  @override
  Duration effectiveInterval = const Duration(seconds: 5);

  @override
  DateTime? startedAt;

  @override
  List<MonitorAlert> alerts = [];

  final List<String> fetchPortsCalls = [];
  final List<String> fetchApplicationsCalls = [];
  final List<String> fetchServicesCalls = [];

  @override
  List<PerformanceSample> getSamples(String connectionId) => [];

  @override
  List<DiskUsageSnapshot> getDiskUsage(String connectionId) => [];

  @override
  ServerHealthSnapshot getHealth(String connectionId) => ServerHealthSnapshot(
    connectionId: connectionId,
    level: ServerHealthLevel.healthy,
    score: 100,
    summary: 'Healthy',
    details: const [],
    updatedAt: DateTime.now(),
  );

  @override
  void setTabIndex(int index) {
    activeTabIndex = index;
    notifyListeners();
  }

  @override
  void setServersCollapsed(bool collapsed) {
    serversCollapsed = collapsed;
    notifyListeners();
  }

  @override
  void setActiveConnection(String? connectionId) {
    activeConnectionId = connectionId;
    notifyListeners();
  }

  @override
  Future<void> startMonitoring({
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    isRunning = true;
    monitoringConnectionIds = Set<String>.of(selectedConnectionIds);
    notifyListeners();
  }

  @override
  void stopMonitoring() {
    isRunning = false;
    notifyListeners();
  }

  @override
  void forceRefresh({SshHostKeyConfirmation? onUnknownHostKey}) {}

  @override
  Future<void> sampleNow({SshHostKeyConfirmation? onUnknownHostKey}) async {}

  @override
  void setInterval(Duration val) {
    interval = val;
    notifyListeners();
  }

  @override
  void setHistoryWindow(Duration val) {
    historyWindow = val;
    notifyListeners();
  }

  @override
  void toggleSelection(String connectionId) {
    if (selectedConnectionIds.contains(connectionId)) {
      selectedConnectionIds.remove(connectionId);
    } else {
      selectedConnectionIds.add(connectionId);
    }
    notifyListeners();
  }

  @override
  Future<List<PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    fetchPortsCalls.add(connectionId);
    return [
      PortProcessSnapshot(
        port: 80,
        protocol: 'tcp',
        localAddress: '0.0.0.0',
        process: 'nginx',
        state: 'LISTEN',
      ),
    ];
  }

  @override
  Future<List<ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    fetchApplicationsCalls.add(connectionId);
    return const [
      ApplicationMemorySnapshot(
        pid: 101,
        command: 'nginx',
        cpuPercent: 0.5,
        rssBytes: 1024 * 1024 * 5,
        memoryPercent: 0.5,
      ),
    ];
  }

  @override
  Future<List<ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    fetchServicesCalls.add(connectionId);
    return [
      ServiceStatusSnapshot(
        name: 'nginx.service',
        displayName: 'Nginx Service',
        status: 'running',
        activeState: 'active',
        loadState: 'loaded',
      ),
    ];
  }

  @override
  List<PerformanceSample> visibleSamplesFor(String connectionId) => [];

  @override
  List<DiskUsageSnapshot> diskUsageFor(String connectionId) => [];

  @override
  ServerHealthSnapshot healthFor(String connectionId) =>
      getHealth(connectionId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late List<ConnectionConfig> fakeConnections;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    appSettings = AppSettings();
    await appSettings.init();

    fakeConnections = [
      ConnectionConfig(
        id: 'conn_123',
        name: 'Test Server',
        host: '127.0.0.1',
        username: 'root',
        serverPlatform: ServerPlatform.linux,
      ),
    ];
  });

  Widget buildTestableWidget({
    required SystemAdminViewModel adminVm,
    required PerformanceMonitorViewModel monitorVm,
    double textScale = 1,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: adminVm),
        ChangeNotifierProvider.value(value: monitorVm),
      ],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: InkRipple.splashFactory,
        ),
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          return MediaQuery(
            data: mediaQuery.copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          );
        },
        home: const SystemAdminScreen(),
      ),
    );
  }

  testWidgets(
    'SystemAdminScreen displays empty state when no server selected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      expect(find.text('选择要监控的服务器'), findsOneWidget);
    },
  );

  testWidgets('Monitor supports multi-select and collapses only after start', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = [
      ...fakeConnections,
      ConnectionConfig(
        id: 'conn_456',
        name: 'Second Server',
        host: '127.0.0.2',
        username: 'operator',
        serverPlatform: ServerPlatform.linux,
      ),
    ];

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('admin-server-tile-conn_123')));
    await tester.drag(
      find.byKey(const ValueKey('admin-server-tile-conn_123')),
      const Offset(-220, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-server-tile-conn_456')));
    await tester.pumpAndSettle();

    expect(monitorVm.selectedConnectionIds, {'conn_123', 'conn_456'});
    expect(adminVm.serversCollapsed, isFalse);

    await tester.tap(find.byKey(const ValueKey('monitor-start')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(monitorVm.monitoringConnectionIds, {'conn_123', 'conn_456'});
    expect(adminVm.serversCollapsed, isTrue);
    expect(
      find.byKey(const ValueKey('admin-server-collapsed')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SystemAdminScreen displays Ports snapshot when server is selected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      adminVm.selectConnection('conn_123');

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Verify TabBar is present
      expect(find.byType(TabBar), findsOneWidget);

      // Switch to Tab 1 (listeningPorts)
      await tester.tap(find.text('监听端口'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('system-admin-workspace-header')),
        findsNothing,
      );
      // Snapshot mode is the default and does not root-connect automatically.
      expect(find.text('快照模式'), findsOneWidget);
      expect(find.text('nginx'), findsWidgets);
      expect(find.text('连接 Root'), findsNothing);
      expect(adminVm.connectIfNeededCalls, 0);
      expect(monitorVm.fetchPortsCalls, ['conn_123']);

      await tester.tap(
        find.byKey(const ValueKey('admin-server-tile-conn_123')),
      );
      await tester.pumpAndSettle();
      expect(adminVm.serversCollapsed, isTrue);
    },
  );

  testWidgets(
    'SystemAdminScreen displays Applications snapshot when server is selected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      adminVm.selectConnection('conn_123');

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Switch to Tab 2 (applications)
      await tester.tap(find.text('应用/进程'));
      await tester.pumpAndSettle();

      // Verify snapshot shows process 'nginx' and 'PID 101'
      expect(find.text('nginx'), findsWidgets);
      expect(find.textContaining('PID 101'), findsOneWidget);
      // Applications does not display a manage mode or Connect Root warning
      expect(find.textContaining('管理模式'), findsNothing);
      expect(find.text('连接 Root'), findsNothing);
    },
  );

  testWidgets(
    'SystemAdminScreen displays Services snapshot when server is selected but not connected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      adminVm.selectConnection('conn_123');

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Switch to Tab 3 (systemServices)
      await tester.tap(find.text('系统服务'));
      await tester.pumpAndSettle();

      // Verify service card nginx.service exists
      expect(find.text('快照模式'), findsOneWidget);
      expect(find.text('nginx.service'), findsWidgets);
      expect(find.text('连接 Root'), findsNothing);
      expect(adminVm.connectIfNeededCalls, 0);
      expect(monitorVm.fetchServicesCalls, ['conn_123']);

      // Snapshot mode does not have the trailing actions PopMenuButton
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    },
  );

  testWidgets(
    'SystemAdminScreen displays Services manage mode when root connected',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      // Simulate root connected
      adminVm.selectedConnectionId = 'conn_123';
      adminVm.managementConnectionId = 'conn_123';
      adminVm.isConnected = true;
      adminVm.isRoot = true;

      // Add some system services in viewModel
      adminVm.services = [
        SystemdService(
          name: 'nginx.service',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          description: 'Nginx Service',
        ),
      ];

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );

      await tester.pumpAndSettle();

      // Switch to Tab 3 (systemServices)
      await tester.tap(find.text('系统服务'));
      await tester.pumpAndSettle();

      // Verify segmented button for Manage/Snapshot exists
      expect(find.text('管理模式'), findsOneWidget);
      expect(find.text('快照模式'), findsOneWidget);

      await tester.tap(find.text('管理模式'));
      await tester.pumpAndSettle();

      // Verify nginx.service exists
      expect(find.text('nginx.service'), findsWidgets);

      // Manage mode has trailing actions PopMenuButton
      expect(find.byType(PopupMenuButton<String>), findsWidgets);
    },
  );

  testWidgets('Services manage mode shows services after lazy fetch', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel()
      ..connections = fakeConnections
      ..populateServicesOnFetch = true;
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('系统服务'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理模式'));
    await tester.pumpAndSettle();

    expect(adminVm.connectIfNeededCalls, 1);
    expect(adminVm.fetchServicesCalls, ['conn_123']);
    expect(find.text('nginx.service'), findsOneWidget);
    expect(find.text('ssh.service'), findsOneWidget);
    expect(find.text('No services found.'), findsNothing);

    await tester.enterText(find.byType(TextField), 'nginx');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('nginx.service'), findsOneWidget);
    expect(find.text('ssh.service'), findsNothing);

    await tester.enterText(find.byType(TextField), 'missing-service');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('nginx.service'), findsNothing);
    expect(find.text('No services found.'), findsOneWidget);
  });

  testWidgets('SystemAdminScreen clears stale selected server safely', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    adminVm.connections = [];
    adminVm.notifyListeners();
    await tester.pumpAndSettle();

    expect(adminVm.selectedConnectionId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Users tab connects and fetches only accounts on activation', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('用户账号'));
    await tester.tap(find.text('用户账号'));
    await tester.pumpAndSettle();

    expect(adminVm.connectIfNeededCalls, 1);
    expect(adminVm.fetchAccountsCalls, ['conn_123']);
    expect(adminVm.fetchSessionsCalls, isEmpty);
    expect(adminVm.fetchServicesCalls, isEmpty);
    expect(adminVm.fetchPortsCalls, isEmpty);
  });

  testWidgets('Power tab connects without preloading management lists', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('系统电源'));
    await tester.tap(find.text('系统电源'));
    await tester.pumpAndSettle();

    expect(adminVm.connectIfNeededCalls, 1);
    expect(adminVm.fetchAccountsCalls, isEmpty);
    expect(adminVm.fetchSessionsCalls, isEmpty);
    expect(adminVm.fetchServicesCalls, isEmpty);
    expect(adminVm.fetchPortsCalls, isEmpty);
  });

  testWidgets('Applications snapshot loads only after tab activation', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    expect(monitorVm.fetchApplicationsCalls, isEmpty);

    await tester.tap(find.text('应用/进程'));
    await tester.pumpAndSettle();

    expect(monitorVm.fetchApplicationsCalls, ['conn_123']);
  });

  testWidgets(
    'Server selection hint uses left on desktop and above on mobile',
    (WidgetTester tester) async {
      final adminVm = StubSystemAdminViewModel();
      final monitorVm = StubPerformanceMonitorViewModel();
      adminVm.connections = fakeConnections;

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('监听端口'));
      await tester.pumpAndSettle();
      expect(find.textContaining('左侧'), findsOneWidget);

      await appSettings.toggleLanguage();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();

      expect(find.textContaining('above'), findsOneWidget);
    },
  );

  testWidgets('System admin workspace stays usable at 320dp with 200% text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm, textScale: 2),
    );
    await tester.pumpAndSettle();

    // The monitor tab begins directly with its live controls, avoiding a
    // duplicate workspace header on compact screens.
    expect(
      find.byKey(const ValueKey('system-admin-workspace-header')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('admin-server-collapse-mobile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-server-tile-conn_123')),
      findsOneWidget,
    );
    final configScroller = find.byKey(
      const ValueKey('monitor-config-horizontal-scroll'),
    );
    expect(configScroller, findsOneWidget);
    expect(
      tester.widget<SingleChildScrollView>(configScroller).scrollDirection,
      Axis.horizontal,
    );
    final controlsRow = tester.widget<Row>(
      find.byKey(const ValueKey('monitor-config-controls-row')),
    );
    expect(controlsRow.mainAxisAlignment, MainAxisAlignment.center);
    await tester.drag(configScroller, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('admin-server-collapse-mobile')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('admin-server-expand-mobile')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Root connection failures use the localized recovery state', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');
    adminVm.managementConnectionId = 'conn_123';
    adminVm.errorMessage = 'Host key verification failed';
    adminVm.connectOnDemand = false;

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('用户账号'));
    await tester.pumpAndSettle();

    expect(find.text('连接失败'), findsWidgets);
    expect(
      find.byKey(const ValueKey('system-admin-connect-root')),
      findsOneWidget,
    );
    expect(find.textContaining('Host key verification failed'), findsOneWidget);
  });

  testWidgets('Snapshot mode controls remain scrollable with 200% text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;
    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(
      buildTestableWidget(adminVm: adminVm, monitorVm: monitorVm, textScale: 2),
    );
    await tester.pumpAndSettle();

    final portsTab = find.text('监听端口');
    await tester.ensureVisible(portsTab);
    await tester.tap(portsTab);
    await tester.pumpAndSettle();
    expect(find.text('快照模式'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final servicesTab = find.text('系统服务');
    await tester.ensureVisible(servicesTab);
    await tester.tap(servicesTab);
    await tester.pumpAndSettle();
    expect(find.text('快照模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
