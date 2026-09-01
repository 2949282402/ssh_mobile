// App Shell Module Scope 与 System Admin 适配器覆盖测试。

import 'package:connection_core/connection_core.dart';
import 'package:drift/drift.dart' as drift;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:feature_terminal/feature_terminal.dart' as feature_terminal;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_ui/app_ui.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/sftp_feature_adapters.dart';
import 'package:ssh_mobile/app/system_admin_feature_adapters.dart';
import 'package:ssh_mobile/app/terminal_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart' as legacy_sftp;

import 'support/feature_adapter_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('terminal and SFTP module scopes expose ready children', (
    tester,
  ) async {
    final terminalManager = FakeSshService();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    });

    await tester.pumpWidget(
      MaterialApp(
        home: InheritedProvider<ssh_core.SshSessionManager>.value(
          value: terminalManager,
          child: AppTerminalModuleScope(
            moduleFactory: () => feature_terminal.TerminalModule(
              databaseFactory: () =>
                  feature_terminal.TerminalDatabase.forTesting(
                    _NoopQueryExecutor(),
                  ),
            ),
            child: const Text('terminal-ready'),
          ),
        ),
      ),
    );
    expect(find.byType(AppSkeletonizer), findsOneWidget);
    await _pumpFrames(tester);
    expect(find.text('terminal-ready'), findsOneWidget);

    final sftpService = FakeSftpService();
    final sftpSettings = FakeAppSettings();
    final sftpLogger = FakeAppLogService();

    await tester.pumpWidget(
      MaterialApp(
        home: AppSftpModuleScope(
          dependencies: (
            sshSessionManager: terminalManager,
            sftpService: sftpService,
            settings: sftpSettings,
            logger: sftpLogger,
            connectionViewModel: null,
          ),
          moduleFactory: () => feature_sftp.SftpModule(
            databaseFactory: () =>
                feature_sftp.SftpDatabase.forTesting(_NoopQueryExecutor()),
          ),
          child: const Text('sftp-ready'),
        ),
      ),
    );
    expect(find.byType(AppSkeletonizer), findsOneWidget);
    await _pumpFrames(tester);
    expect(find.text('sftp-ready'), findsOneWidget);
  });

  test(
    'System Admin connection, file, logger, and monitoring adapters map ports',
    () async {
      final config = ConnectionConfig(
        id: 'server-a',
        name: 'Server A',
        host: 'server-a.example.test',
        username: 'root',
      );
      final repository = _AdminConnectionRepository(config);
      final catalog = AppSystemAdminConnectionCatalogAdapter(repository);
      var catalogNotifications = 0;
      catalog.addListener(() => catalogNotifications++);
      expect(catalog.isInitialized, isTrue);
      expect(catalog.connections.single.id, 'server-a');
      expect(catalog.connectionById('server-a'), same(config));
      expect(catalog.connectionById('missing'), isNull);
      await catalog.reorderConnections(0, 1);
      expect(repository.reorders, [(0, 1)]);
      expect(catalogNotifications, 1);
      catalog.dispose();

      final sftp = FakeSftpService()
        ..listResult = <legacy_sftp.SftpEntry>[
          legacy_sftp.SftpEntry(
            connectionId: 'server-a',
            targetFingerprint: 'fp',
            name: 'home',
            path: '/home',
            lowerName: 'home',
            isDirectory: true,
            isLink: false,
            size: 0,
            sizeLabel: '',
            modifiedAt: null,
            modifiedLabel: null,
          ),
        ];
      final browser = AppSystemAdminFileBrowserAdapter(sftp);
      final files = await browser.listDirectoryForConnection('server-a', '/');
      expect(files.single.name, 'home');
      expect(files.single.path, '/home');
      expect(files.single.isDirectory, isTrue);
      expect(files.single.sizeLabel, isEmpty);
      expect(files.single.modifiedLabel, isNull);

      final logger = FakeAppLogService();
      final loggerAdapter = AppSystemAdminLoggerAdapter(logger);
      final failure = StateError('failure');
      final stackTrace = StackTrace.current;
      loggerAdapter.info('info', details: 'i');
      loggerAdapter.warning('warning');
      loggerAdapter.error(
        'error',
        error: failure,
        stackTrace: stackTrace,
        details: 'e',
      );
      expect(logger.calls.map((call) => call.level), [
        'info',
        'warning',
        'error',
      ]);
      expect(logger.calls.last.error, same(failure));

      final monitoringService = _FakeMonitoringService();
      final monitoringAdapter = AppSystemAdminMonitoringAdapter(
        monitoringService,
      );
      var monitoringNotifications = 0;
      monitoringAdapter.addListener(() => monitoringNotifications++);
      expect(monitoringAdapter.isRunning, isTrue);
      expect(monitoringAdapter.isSampling, isFalse);
      expect(monitoringAdapter.selectedConnectionIds, {'server-a'});
      expect(monitoringAdapter.monitoringConnectionIds, {'server-a'});
      expect(monitoringAdapter.interval, const Duration(seconds: 10));
      expect(monitoringAdapter.historyWindow, const Duration(minutes: 5));
      expect(monitoringAdapter.effectiveInterval, const Duration(seconds: 20));
      expect(monitoringAdapter.startedAt, isNotNull);

      final alert = monitoringAdapter.alerts.single;
      expect(alert.id, 'alert-1');
      expect(alert.level, admin.ServerHealthLevel.warning);
      final sample = monitoringAdapter.visibleSamplesFor('server-a').single;
      expect(sample.cpuPercent, 12.5);
      expect(sample.networkBytesPerSecond, 8);
      final disk = monitoringAdapter.diskUsageFor('server-a').single;
      expect(disk.mount, '/');
      expect(disk.usedPercent, 42.5);
      final health = monitoringAdapter.healthFor('server-a');
      expect(health.level, admin.ServerHealthLevel.healthy);
      expect(health.details, ['ok']);

      await monitoringAdapter.startMonitoring();
      monitoringAdapter.stopMonitoring();
      await monitoringAdapter.sampleNow();
      monitoringAdapter.setInterval(const Duration(seconds: 5));
      monitoringAdapter.setHistoryWindow(const Duration(minutes: 2));
      monitoringAdapter.toggleSelection('server-b');
      final ports = await monitoringAdapter.fetchPorts('server-a');
      final applications = await monitoringAdapter.fetchApplications(
        'server-a',
      );
      final services = await monitoringAdapter.fetchServices('server-a');
      expect(ports.single.port, 22);
      expect(applications.single.pid, 42);
      expect(services.single.name, 'sshd');
      expect(
        monitoringService.calls,
        containsAll(<String>[
          'start',
          'stop',
          'sample',
          'interval',
          'history',
          'toggle',
          'ports',
          'applications',
          'services',
        ]),
      );
      monitoringAdapter.dispose();
      monitoringService.emitChange();
      expect(monitoringNotifications, 0);
    },
  );

  testWidgets('System Admin host key adapter shows and returns dialog result', (
    tester,
  ) async {
    final settings = FakeAppSettings()..language = AppLanguage.en;
    late BuildContext capturedContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppSettings>.value(
          value: settings,
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final adapter = AppSystemAdminHostKeyConfirmationAdapter(capturedContext);
    final confirmation = adapter.confirm(
      const ssh_core.SshHostKeyPromptRequest(
        connectionId: 'server-a',
        connectionName: 'Server A',
        host: 'server-a.example.test',
        port: 22,
        username: 'root',
        algorithm: 'ssh-ed25519',
        fingerprint: 'SHA256:test',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Trust SSH host key?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await confirmation, isFalse);
  });

  testWidgets('System Admin module scope initializes and releases resources', (
    tester,
  ) async {
    final config = ConnectionConfig(
      id: 'admin-server',
      name: 'Admin server',
      host: 'admin.example.test',
      username: 'root',
    );
    final connectionRepository = _AdminConnectionRepository(config);
    final settings = FakeAppSettings()..language = AppLanguage.en;
    final logger = FakeAppLogService();
    final monitoringService = _FakeMonitoringService();
    final sftpService = FakeSftpService();

    await tester.pumpWidget(
      MaterialApp(
        home: AppSystemAdminModuleScope(
          dependencies: (
            connectionRepository: connectionRepository,
            credentialRepository: _AdminCredentialRepository(),
            hostKeyRepository: _AdminHostKeyRepository(),
            logger: logger,
            settings: settings,
            sftpService: sftpService,
            monitoringService: monitoringService,
            nativeStreamConnector: null,
          ),
          child: const Text('admin-ready'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('admin-ready'), findsOneWidget);
    await _pumpFrames(tester);
    expect(find.text('admin-ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var index = 0; index < 20; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final class _AdminConnectionRepository implements ConnectionRepository {
  _AdminConnectionRepository(this.current);

  ConnectionConfig? current;
  final List<(int, int)> reorders = <(int, int)>[];

  @override
  List<ConnectionConfig> get connections =>
      current == null ? const <ConnectionConfig>[] : [current!];

  @override
  ConnectionConfig? getConnection(String id) =>
      current?.id == id ? current : null;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ConnectionConfig>> loadConnections() async => connections;

  @override
  Future<void> addConnection(ConnectionConfig config) async => current = config;

  @override
  Future<void> updateConnection(ConnectionConfig config) async =>
      current = config;

  @override
  Future<void> deleteConnection(String id) async => current = null;

  @override
  Future<void> deleteConnections(List<String> ids) async => current = null;

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    reorders.add((oldIndex, newIndex));
  }
}

final class _AdminCredentialRepository extends Fake
    implements CredentialRepository {}

final class _AdminHostKeyRepository extends Fake implements HostKeyRepository {}

final class _FakeMonitoringService extends Fake
    implements monitoring.MonitoringService {
  final List<VoidCallback> _listeners = <VoidCallback>[];
  final List<String> calls = <String>[];

  @override
  bool isRunning = true;
  @override
  bool isSampling = false;
  @override
  Set<String> selectedConnectionIds = {'server-a'};
  @override
  Set<String> monitoringConnectionIds = {'server-a'};
  @override
  Duration interval = const Duration(seconds: 10);
  @override
  Duration historyWindow = const Duration(minutes: 5);
  @override
  Duration effectiveInterval = const Duration(seconds: 20);
  @override
  DateTime? startedAt = DateTime.utc(2026, 1, 1);
  @override
  List<monitoring.MonitorAlert> alerts = <monitoring.MonitorAlert>[
    monitoring.MonitorAlert(
      id: 'alert-1',
      connectionId: 'server-a',
      metric: 'cpu',
      level: monitoring.ServerHealthLevel.warning,
      message: 'High CPU',
      createdAt: DateTime.utc(2026, 1, 1),
    ),
  ];

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void emitChange() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  List<monitoring.PerformanceSample> visibleSamplesFor(String connectionId) =>
      <monitoring.PerformanceSample>[
        monitoring.PerformanceSample(
          connectionId: connectionId,
          time: DateTime.utc(2026, 1, 1),
          cpuPercent: 12.5,
          memoryPercent: 25,
          diskBytesPerSecond: 4,
          networkBytesPerSecond: 8,
        ),
      ];

  @override
  List<monitoring.DiskUsageSnapshot> diskUsageFor(String connectionId) =>
      const <monitoring.DiskUsageSnapshot>[
        monitoring.DiskUsageSnapshot(
          filesystem: '/dev/sda',
          mount: '/',
          totalBytes: 100,
          usedBytes: 42,
          availableBytes: 58,
          usedPercent: 42.5,
        ),
      ];

  @override
  monitoring.ServerHealthSnapshot healthFor(String connectionId) =>
      monitoring.ServerHealthSnapshot(
        connectionId: connectionId,
        level: monitoring.ServerHealthLevel.healthy,
        score: 90,
        summary: 'Healthy',
        details: const ['ok'],
        updatedAt: DateTime.utc(2026, 1, 1),
      );

  @override
  Future<void> startMonitoring({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    Map<String, ssh_core.SshTargetBinding>? targetBindings,
  }) async {
    calls.add('start');
  }

  @override
  void stopMonitoring() => calls.add('stop');

  @override
  Future<void> sampleNow({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    calls.add('sample');
  }

  @override
  void setInterval(Duration value) {
    calls.add('interval');
    interval = value;
  }

  @override
  void setHistoryWindow(Duration value) {
    calls.add('history');
    historyWindow = value;
  }

  @override
  void toggleSelection(String connectionId) => calls.add('toggle');

  @override
  Future<List<monitoring.PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    calls.add('ports');
    return const <monitoring.PortProcessSnapshot>[
      monitoring.PortProcessSnapshot(
        protocol: 'tcp',
        localAddress: '0.0.0.0',
        port: 22,
        state: 'LISTEN',
        process: 'sshd',
      ),
    ];
  }

  @override
  Future<List<monitoring.ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    calls.add('applications');
    return const <monitoring.ApplicationMemorySnapshot>[
      monitoring.ApplicationMemorySnapshot(
        pid: 42,
        command: 'sshd',
        rssBytes: 100,
        memoryPercent: 1.5,
        cpuPercent: 2.5,
      ),
    ];
  }

  @override
  Future<List<monitoring.ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    calls.add('services');
    return const <monitoring.ServiceStatusSnapshot>[
      monitoring.ServiceStatusSnapshot(
        name: 'sshd',
        displayName: 'SSH daemon',
        status: 'running',
        activeState: 'active',
        loadState: 'loaded',
      ),
    ];
  }
}

/// Scope 生命周期只需要一个可打开、可执行 `SELECT 1` 的 Drift Executor；
/// 使用测试替身避免 Flutter tester 在 WSL 中加载平台 SQLite 动态库。
final class _NoopQueryExecutor extends Fake implements drift.QueryExecutor {
  @override
  drift.SqlDialect get dialect => drift.SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(drift.QueryExecutorUser user) async => true;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async => <Map<String, Object?>>[<String, Object?>{}];

  @override
  Future<int> runInsert(String statement, List<Object?> args) async => 1;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async => 1;

  @override
  Future<int> runDelete(String statement, List<Object?> args) async => 1;

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async {}

  @override
  Future<void> runBatched(drift.BatchedStatements statements) async {}

  @override
  drift.TransactionExecutor beginTransaction() =>
      throw UnimplementedError('transactions are not used by scope tests');

  @override
  drift.QueryExecutor beginExclusive() => this;

  @override
  Future<void> close() async {}
}
