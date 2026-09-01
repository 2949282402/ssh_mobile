import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_ui/app_ui.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/system_admin_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late AppSystemAdminSettingsAdapter settingsAdapter;
  late _StubAdminVm adminVm;
  late _StubMonitorVm monitorVm;
  late List<ConnectionConfig> fakeConnections;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    appSettings = AppSettings();
    await appSettings.init();
    settingsAdapter = AppSystemAdminSettingsAdapter(appSettings);

    fakeConnections = [
      ConnectionConfig(
        id: 'conn_123',
        name: 'Test Server',
        host: '127.0.0.1',
        username: 'root',
        serverPlatform: ServerPlatform.linux,
      ),
    ];

    adminVm = _StubAdminVm()
      ..connections = fakeConnections
      ..selectedConnectionId = 'conn_123'
      ..isConnected = true
      ..isRoot = true
      ..managementConnectionId = 'conn_123';

    monitorVm = _StubMonitorVm();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    appSettings.dispose();
  });

  Future<void> pumpSystemAdmin(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<admin.SystemAdminSettingsPort>.value(
            value: settingsAdapter,
          ),
          ChangeNotifierProvider<admin.SystemAdminViewModel>.value(
            value: adminVm,
          ),
          ListenableProvider<admin.SystemAdminMonitoringPort>.value(
            value: monitorVm,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
          home: const Scaffold(body: admin.SystemAdminScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  group('System Admin Workspace Desktop Resolutions', () {
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
            await pumpSystemAdmin(
              tester,
              size: size,
              platform: TargetPlatform.windows,
            );

            expect(find.byType(admin.SystemAdminScreen), findsOneWidget);
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

  group('System Admin Workspace Mobile Resolutions', () {
    const mobileWidths = [320.0, 390.0, 430.0];

    for (final width in mobileWidths) {
      testWidgets('renders cleanly on ${width.toInt()}px mobile', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpSystemAdmin(
            tester,
            size: Size(width, 800),
            platform: TargetPlatform.android,
          );

          expect(find.byType(admin.SystemAdminScreen), findsOneWidget);
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

class _StubAdminVm extends ChangeNotifier
    implements admin.SystemAdminViewModel {
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
  List<admin.LinuxUserAccount> accounts = [];

  @override
  bool loadingAccounts = false;

  @override
  List<admin.ActiveSession> sessions = [];

  @override
  bool loadingSessions = false;

  @override
  List<admin.SystemdService> services = [];

  @override
  bool loadingServices = false;

  @override
  List<admin.ListeningPort> ports = [];

  @override
  bool loadingPorts = false;

  @override
  List<ConnectionConfig> connections = [];

  @override
  String? get connectionId => selectedConnectionId;

  @override
  String? get activeManagementConnectionId => managementConnectionId;

  @override
  admin.SystemAdminSessionTarget? get activeManagementTarget {
    final id = activeManagementConnectionId;
    final config = connectionById(id);
    if (id == null || config == null || !isConnected || !isRoot) return null;
    return admin.SystemAdminSessionTarget(
      binding: ssh_core.SshTargetBinding.fromConfig(config),
      generation: 1,
    );
  }

  @override
  bool get canManageSelectedConnection =>
      activeManagementConnectionId != null && isConnected && isRoot;

  @override
  bool get isConnectingSelectedConnection =>
      managementConnectionId == selectedConnectionId && isConnecting;

  @override
  bool get isConnectedSelectedConnection =>
      managementConnectionId == selectedConnectionId && isConnected;

  @override
  bool get hasManagementErrorForSelectedConnection =>
      managementConnectionId == selectedConnectionId && errorMessage != null;

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
  bool isConnectingConnection(String id) =>
      managementConnectionId == id && isConnecting;

  @override
  void selectConnection(String id) {
    selectedConnectionId = id;
    notifyListeners();
  }

  @override
  Future<void> connect(
    String id, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    managementConnectionId = id;
    isConnected = true;
    isRoot = true;
    notifyListeners();
  }

  @override
  Future<void> connectIfNeeded(
    String id, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (selectedConnectionId != id) return;
    if (canManageSelectedConnection) return;
    await connect(id, onUnknownHostKey: onUnknownHostKey);
  }

  @override
  Future<void> disconnect() async {
    managementConnectionId = null;
    isConnected = false;
    isRoot = false;
    notifyListeners();
  }

  @override
  Future<void> disconnectTarget(admin.SystemAdminSessionTarget target) async {
    if (activeManagementTarget?.matches(target) ?? false) await disconnect();
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
    selectedConnectionId = null;
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
  Future<void> fetchAccounts(String connId, {bool force = false}) async {}

  @override
  Future<void> fetchSessions(String connId, {bool force = false}) async {}

  @override
  Future<void> fetchServices(String connId, {bool force = false}) async {}

  @override
  Future<void> fetchPorts(String connId, {bool force = false}) async {}

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
  Future<List<admin.LinuxUserProcess>> getUserProcessesAndMemory(
    String username,
  ) async => [];

  @override
  Future<void> killActiveSession(String tty) async {}

  @override
  Future<void> manageSystemdService(String serviceName, String action) async {}

  @override
  Future<void> rebootServer(admin.SystemPowerConfirmationToken token) async {}

  @override
  Future<void> shutdownServer(admin.SystemPowerConfirmationToken token) async {}
}

class _StubMonitorVm extends ChangeNotifier
    implements admin.SystemAdminMonitoringPort {
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
  List<admin.MonitorAlert> alerts = [];

  @override
  Future<void> startMonitoring({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    isRunning = true;
    notifyListeners();
  }

  @override
  void stopMonitoring() {
    isRunning = false;
    notifyListeners();
  }

  @override
  Future<void> sampleNow({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {}

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
  Future<List<admin.PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => [];

  @override
  Future<List<admin.ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => [];

  @override
  Future<List<admin.ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => [];

  @override
  List<admin.PerformanceSample> visibleSamplesFor(String connectionId) => [];

  @override
  List<admin.DiskUsageSnapshot> diskUsageFor(String connectionId) => [];

  @override
  admin.ServerHealthSnapshot healthFor(String connectionId) =>
      admin.ServerHealthSnapshot(
        connectionId: connectionId,
        level: admin.ServerHealthLevel.healthy,
        score: 100,
        summary: 'Healthy',
        details: const [],
        updatedAt: DateTime.now(),
      );
}
