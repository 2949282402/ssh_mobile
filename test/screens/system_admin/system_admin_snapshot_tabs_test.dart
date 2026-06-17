import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/screens/system_admin_screen.dart';
import 'package:ssh_mobile/features/system_admin/viewmodels/system_admin_viewmodel.dart';
import 'package:ssh_mobile/features/performance/viewmodels/performance_viewmodel.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/models/system_admin.dart';
import 'package:ssh_mobile/services/server_status_probe.dart';

class StubSystemAdminViewModel extends ChangeNotifier implements SystemAdminViewModel {
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

  @override
  String? get connectionId => selectedConnectionId;

  @override
  void selectConnection(String id) {
    selectedConnectionId = id;
    notifyListeners();
  }

  @override
  Future<void> connect(String id) async {
    selectedConnectionId = id;
    managementConnectionId = id;
    isConnected = true;
    isRoot = true;
    notifyListeners();
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
  Future<void> refreshAllData() async {}

  @override
  Future<void> fetchAccounts(String connId) async {}

  @override
  Future<void> fetchSessions(String connId) async {}

  @override
  Future<void> fetchServices(String connId) async {}

  @override
  Future<void> fetchPorts(String connId) async {}

  @override
  Future<void> createUser(String username, String password, {String shell = '/bin/bash'}) async {}

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
  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(String username) async => [];

  @override
  Future<void> killActiveSession(String tty) async {}

  @override
  Future<void> manageSystemdService(String serviceName, String action) async {}

  @override
  Future<void> rebootServer() async {}

  @override
  Future<void> shutdownServer() async {}
}

class StubPerformanceMonitorViewModel extends ChangeNotifier implements PerformanceMonitorViewModel {
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
  Future<void> startMonitoring() async {
    isRunning = true;
    notifyListeners();
  }

  @override
  void stopMonitoring() {
    isRunning = false;
    notifyListeners();
  }

  @override
  void forceRefresh() {}

  @override
  Future<void> sampleNow() async {}

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
  Future<List<PortProcessSnapshot>> fetchPorts(String connectionId) async {
    return [
      PortProcessSnapshot(port: 80, protocol: 'tcp', localAddress: '0.0.0.0', process: 'nginx', state: 'LISTEN'),
    ];
  }

  @override
  Future<List<ApplicationMemorySnapshot>> fetchApplications(String connectionId) async {
    return const [
      ApplicationMemorySnapshot(pid: 101, command: 'nginx', cpuPercent: 0.5, rssBytes: 1024 * 1024 * 5, memoryPercent: 0.5),
    ];
  }

  @override
  Future<List<ServiceStatusSnapshot>> fetchServices(String connectionId) async {
    return [
      ServiceStatusSnapshot(name: 'nginx.service', displayName: 'Nginx Service', status: 'running', activeState: 'active', loadState: 'loaded'),
    ];
  }

  @override
  List<PerformanceSample> visibleSamplesFor(String connectionId) => [];

  @override
  List<DiskUsageSnapshot> diskUsageFor(String connectionId) => [];

  @override
  ServerHealthSnapshot healthFor(String connectionId) => getHealth(connectionId);
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
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: adminVm),
        ChangeNotifierProvider.value(value: monitorVm),
      ],
      child: const MaterialApp(
        home: SystemAdminScreen(),
      ),
    );
  }

  testWidgets('SystemAdminScreen displays empty state when no server selected',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;

    await tester.pumpWidget(buildTestableWidget(
      adminVm: adminVm,
      monitorVm: monitorVm,
    ));

    expect(find.text('选择要监控的服务器'), findsOneWidget);
  });

  testWidgets('SystemAdminScreen displays Ports snapshot when server is selected',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final adminVm = StubSystemAdminViewModel();
    final monitorVm = StubPerformanceMonitorViewModel();
    adminVm.connections = fakeConnections;

    adminVm.selectConnection('conn_123');

    await tester.pumpWidget(buildTestableWidget(
      adminVm: adminVm,
      monitorVm: monitorVm,
    ));

    await tester.pumpAndSettle();

    // Verify TabBar is present
    expect(find.byType(TabBar), findsOneWidget);

    // Switch to Tab 1 (listeningPorts)
    await tester.tap(find.text('监听端口'));
    await tester.pumpAndSettle();

    // Verify snapshot mode is active because not root connected
    expect(find.textContaining('当前无法使用管理模式（需要 root 权限）'), findsOneWidget);
    expect(find.text('连接 Root'), findsOneWidget);
  });
}
