// System Admin Feature 的 App Shell 适配器。
//
// App Shell 负责把旧 Storage/SFTP、App 文案和 Runtime Monitoring 转换为
// Feature Port。适配器本身不拥有 App Scope 的 SSH、SFTP 或 Monitoring；
// Route Scope 只拥有 SystemAdminModule 创建的管理会话。

import 'dart:async';
import 'package:app_core/app_core.dart';
import 'package:app_ui/app_ui.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/ssh_host_key_policy.dart' as legacy_ssh;
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../widgets/ssh_host_key_trust_dialog.dart';
import 'app_runtime.dart';
import 'system_admin_settings_adapter.dart';
import 'system_admin_ssh_adapter.dart';

export 'system_admin_settings_adapter.dart';
export 'system_admin_ssh_adapter.dart';

/// 将 Connection Core 的连接目录适配为 System Admin Port。
final class AppSystemAdminConnectionCatalogAdapter extends ChangeNotifier
    implements admin.SystemAdminConnectionCatalogPort {
  /// 创建不拥有 Connection Repository 的目录适配器。
  AppSystemAdminConnectionCatalogAdapter(this._repository);

  final connection_core.ConnectionRepository _repository;

  @override
  bool get isInitialized => true;

  @override
  List<connection_core.ConnectionConfig> get connections =>
      _repository.connections;

  @override
  connection_core.ConnectionConfig? connectionById(String id) =>
      _repository.getConnection(id);

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    await _repository.reorderConnections(oldIndex, newIndex);
    notifyListeners();
  }
}

/// 将 SFTP 的目录读取能力限制为家目录浏览所需的快照。
final class AppSystemAdminFileBrowserAdapter
    implements admin.SystemAdminFileBrowserPort {
  /// 创建不拥有 SFTP Service 的适配器。
  const AppSystemAdminFileBrowserAdapter(this._sftp);

  final SftpService _sftp;

  @override
  Future<List<admin.SystemAdminFileEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) async {
    final entries = await _sftp.listDirectoryForConnection(connectionId, path);
    return [
      for (final entry in entries)
        admin.SystemAdminFileEntry(
          name: entry.name,
          path: entry.path,
          isDirectory: entry.isDirectory,
          sizeLabel: entry.sizeLabel,
          modifiedLabel: entry.modifiedLabel,
        ),
    ];
  }
}

/// 将旧 AppLogService 适配为 Feature 日志 Port。
final class AppSystemAdminLoggerAdapter implements admin.SystemAdminLoggerPort {
  /// 创建不拥有 Logger 的适配器。
  const AppSystemAdminLoggerAdapter(this._logger);

  final AppLogService _logger;

  @override
  void info(String message, {String? details}) =>
      _logger.info(message, details: details);

  @override
  void warning(String message, {String? details}) =>
      _logger.warning(message, details: details);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) => _logger.error(
    message,
    error: error,
    stackTrace: stackTrace,
    details: details,
  );
}

/// 将 Monitoring 公共服务转换为 System Admin 的小型 Capability。
final class AppSystemAdminMonitoringAdapter extends ChangeNotifier
    implements admin.SystemAdminMonitoringPort {
  /// 创建不拥有 MonitoringService 的适配器。
  AppSystemAdminMonitoringAdapter(this._monitoring) {
    _monitoring.addListener(notifyListeners);
  }

  final monitoring.MonitoringService _monitoring;

  @override
  bool get isRunning => _monitoring.isRunning;
  @override
  bool get isSampling => _monitoring.isSampling;
  @override
  Set<String> get selectedConnectionIds => _monitoring.selectedConnectionIds;
  @override
  Set<String> get monitoringConnectionIds =>
      _monitoring.monitoringConnectionIds;
  @override
  Duration get interval => _monitoring.interval;
  @override
  Duration get historyWindow => _monitoring.historyWindow;
  @override
  Duration get effectiveInterval => _monitoring.effectiveInterval;
  @override
  DateTime? get startedAt => _monitoring.startedAt;
  @override
  List<admin.MonitorAlert> get alerts => [
    for (final alert in _monitoring.alerts) _toAlert(alert),
  ];

  @override
  List<admin.PerformanceSample> visibleSamplesFor(String connectionId) => [
    for (final sample in _monitoring.visibleSamplesFor(connectionId))
      _toSample(sample),
  ];

  @override
  List<admin.DiskUsageSnapshot> diskUsageFor(String connectionId) => [
    for (final disk in _monitoring.diskUsageFor(connectionId)) _toDisk(disk),
  ];

  @override
  admin.ServerHealthSnapshot healthFor(String connectionId) =>
      _toHealth(_monitoring.healthFor(connectionId));

  @override
  Future<void> startMonitoring({
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) => _monitoring.startMonitoring(onUnknownHostKey: onUnknownHostKey);

  @override
  void stopMonitoring() => _monitoring.stopMonitoring();

  @override
  Future<void> sampleNow({ssh_core.SshHostKeyConfirmation? onUnknownHostKey}) =>
      _monitoring.sampleNow(onUnknownHostKey: onUnknownHostKey);

  @override
  void setInterval(Duration value) => _monitoring.setInterval(value);

  @override
  void setHistoryWindow(Duration value) => _monitoring.setHistoryWindow(value);

  @override
  void toggleSelection(String connectionId) =>
      _monitoring.toggleSelection(connectionId);

  @override
  Future<List<admin.PortProcessSnapshot>> fetchPorts(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => [
    for (final port in await _monitoring.fetchPorts(
      connectionId,
      onUnknownHostKey: onUnknownHostKey,
    ))
      _toPort(port),
  ];

  @override
  Future<List<admin.ApplicationMemorySnapshot>> fetchApplications(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => [
    for (final app in await _monitoring.fetchApplications(
      connectionId,
      onUnknownHostKey: onUnknownHostKey,
    ))
      _toApplication(app),
  ];

  @override
  Future<List<admin.ServiceStatusSnapshot>> fetchServices(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async => [
    for (final service in await _monitoring.fetchServices(
      connectionId,
      onUnknownHostKey: onUnknownHostKey,
    ))
      _toService(service),
  ];

  @override
  void dispose() {
    _monitoring.removeListener(notifyListeners);
    super.dispose();
  }

  static admin.MonitorAlert _toAlert(monitoring.MonitorAlert alert) =>
      admin.MonitorAlert(
        id: alert.id,
        connectionId: alert.connectionId,
        metric: alert.metric,
        level: _toLevel(alert.level),
        message: alert.message,
        createdAt: alert.createdAt,
      );

  static admin.PerformanceSample _toSample(
    monitoring.PerformanceSample sample,
  ) => admin.PerformanceSample(
    connectionId: sample.connectionId,
    time: sample.time,
    cpuPercent: sample.cpuPercent,
    memoryPercent: sample.memoryPercent,
    diskBytesPerSecond: sample.diskBytesPerSecond,
    networkBytesPerSecond: sample.networkBytesPerSecond,
  );

  static admin.DiskUsageSnapshot _toDisk(monitoring.DiskUsageSnapshot disk) =>
      admin.DiskUsageSnapshot(
        filesystem: disk.filesystem,
        mount: disk.mount,
        totalBytes: disk.totalBytes,
        usedBytes: disk.usedBytes,
        availableBytes: disk.availableBytes,
        usedPercent: disk.usedPercent,
      );

  static admin.ServerHealthSnapshot _toHealth(
    monitoring.ServerHealthSnapshot health,
  ) => admin.ServerHealthSnapshot(
    connectionId: health.connectionId,
    level: _toLevel(health.level),
    score: health.score,
    summary: health.summary,
    details: health.details,
    updatedAt: health.updatedAt,
  );

  static admin.PortProcessSnapshot _toPort(
    monitoring.PortProcessSnapshot port,
  ) => admin.PortProcessSnapshot(
    protocol: port.protocol,
    localAddress: port.localAddress,
    port: port.port,
    state: port.state,
    process: port.process,
  );

  static admin.ApplicationMemorySnapshot _toApplication(
    monitoring.ApplicationMemorySnapshot app,
  ) => admin.ApplicationMemorySnapshot(
    pid: app.pid,
    command: app.command,
    rssBytes: app.rssBytes,
    memoryPercent: app.memoryPercent,
    cpuPercent: app.cpuPercent,
  );

  static admin.ServiceStatusSnapshot _toService(
    monitoring.ServiceStatusSnapshot service,
  ) => admin.ServiceStatusSnapshot(
    name: service.name,
    displayName: service.displayName,
    status: service.status,
    activeState: service.activeState,
    loadState: service.loadState,
  );

  static admin.ServerHealthLevel _toLevel(monitoring.ServerHealthLevel level) =>
      admin.ServerHealthLevel.values.byName(level.name);
}

/// App Shell 的 Host Key 对话框能力；只拥有一次性的 BuildContext 引用。
final class AppSystemAdminHostKeyConfirmationAdapter
    implements admin.SystemAdminHostKeyConfirmationPort {
  /// 创建对话框适配器。
  const AppSystemAdminHostKeyConfirmationAdapter(this._context);

  final BuildContext _context;

  @override
  Future<bool> confirm(ssh_core.SshHostKeyPromptRequest request) {
    return showSshHostKeyTrustDialog(_context, _toLegacyPrompt(request));
  }
}

/// 在旧系统管理页面仍使用时提供兼容的单次转换。
legacy_ssh.SshHostKeyPromptRequest _toLegacyPrompt(
  ssh_core.SshHostKeyPromptRequest request,
) => legacy_ssh.SshHostKeyPromptRequest(
  connectionId: request.connectionId,
  connectionName: request.connectionName,
  host: request.host,
  port: request.port,
  username: request.username,
  algorithm: request.algorithm,
  fingerprint: request.fingerprint,
);

/// Test-only dependency bundle for the System Admin module scope.
///
/// Production routes still resolve the same ports from [AppRuntime].  Tests
/// can inject lightweight fakes so scope lifecycle assertions do not need to
/// initialize unrelated App Scope databases.
typedef AppSystemAdminModuleScopeDependencies = ({
  connection_core.ConnectionRepository connectionRepository,
  connection_core.CredentialRepository credentialRepository,
  connection_core.HostKeyRepository hostKeyRepository,
  AppLogService logger,
  AppSettings settings,
  SftpService sftpService,
  monitoring.MonitoringService monitoringService,
  ssh_core.SshNativeStreamConnector? nativeStreamConnector,
});

/// Stateful Route Scope；Module 是本 Scope 的唯一管理服务 Owner。
final class AppSystemAdminModuleScope extends StatefulWidget {
  /// 创建 System Admin 页面 Scope。
  const AppSystemAdminModuleScope({
    super.key,
    required this.child,
    @visibleForTesting this.dependencies,
  });

  final Widget child;

  /// Optional test dependencies that bypass the AppRuntime composition root.
  @visibleForTesting
  final AppSystemAdminModuleScopeDependencies? dependencies;

  @override
  State<AppSystemAdminModuleScope> createState() =>
      _AppSystemAdminModuleScopeState();
}

final class _AppSystemAdminModuleScopeState
    extends State<AppSystemAdminModuleScope> {
  admin.SystemAdminModule? _module;
  AppSystemAdminConnectionCatalogAdapter? _catalog;
  AppSystemAdminSettingsAdapter? _settings;
  AppSystemAdminMonitoringAdapter? _monitoring;
  AppSystemAdminFileBrowserAdapter? _fileBrowser;
  Future<void>? _readyFuture;
  Future<void>? _disposeFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_module != null) return;

    final dependencies = widget.dependencies;
    final runtime = dependencies == null ? context.read<AppRuntime>() : null;
    _catalog = AppSystemAdminConnectionCatalogAdapter(
      dependencies?.connectionRepository ?? runtime!.connectionRepository,
    );
    _settings = AppSystemAdminSettingsAdapter(
      dependencies?.settings ?? runtime!.appSettings,
    );
    _monitoring = AppSystemAdminMonitoringAdapter(
      dependencies?.monitoringService ?? runtime!.monitoringService,
    );
    _fileBrowser = AppSystemAdminFileBrowserAdapter(
      dependencies?.sftpService ?? runtime!.sftpService,
    );
    final module = admin.SystemAdminModule();
    _module = module;
    _readyFuture = _initializeModule(module, runtime, dependencies);
  }

  Future<void> _initializeModule(
    admin.SystemAdminModule module,
    AppRuntime? runtime,
    AppSystemAdminModuleScopeDependencies? dependencies,
  ) async {
    final connectionRepository =
        dependencies?.connectionRepository ?? runtime!.connectionRepository;
    final credentialRepository =
        dependencies?.credentialRepository ?? runtime!.credentialRepository;
    final hostKeyRepository =
        dependencies?.hostKeyRepository ?? runtime!.hostKeyRepository;
    final logger = dependencies?.logger ?? runtime!.appLogService;
    final nativeStreamConnector = dependencies == null
        ? runtime!.sshNativeStreamConnector
        : dependencies.nativeStreamConnector;
    await module.register(
      ModuleContext.fromMap({
        admin.SystemAdminSshPort: AppSystemAdminSshAdapter(
          connectionRepository,
          credentialRepository: credentialRepository,
          hostKeyRepository: hostKeyRepository,
          logger: logger,
          nativeStreamConnector: nativeStreamConnector,
        ),
        admin.SystemAdminLoggerPort: AppSystemAdminLoggerAdapter(logger),
      }),
    );
    await module.activate();
  }

  @override
  void dispose() {
    final module = _module;
    final catalog = _catalog;
    final settings = _settings;
    final monitoringPort = _monitoring;
    _module = null;
    _catalog = null;
    _settings = null;
    _monitoring = null;
    _fileBrowser = null;
    _readyFuture = null;
    _disposeFuture = _disposeOwnedResources(
      module: module,
      catalog: catalog,
      settings: settings,
      monitoring: monitoringPort,
    );
    unawaited(
      _disposeFuture!.catchError((Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'ssh_mobile system admin route scope',
            context: ErrorDescription('while disposing route resources'),
          ),
        );
      }),
    );
    super.dispose();
  }

  static Future<void> _disposeOwnedResources({
    required admin.SystemAdminModule? module,
    required AppSystemAdminConnectionCatalogAdapter? catalog,
    required AppSystemAdminSettingsAdapter? settings,
    required AppSystemAdminMonitoringAdapter? monitoring,
  }) async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (module != null) await attempt(module.dispose);
    if (catalog != null) await attempt(catalog.dispose);
    if (settings != null) await attempt(settings.dispose);
    if (monitoring != null) await attempt(monitoring.dispose);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final module = _module;
    final catalog = _catalog;
    final settings = _settings;
    final monitoringPort = _monitoring;
    final fileBrowser = _fileBrowser;
    final readyFuture = _readyFuture;
    if (module == null ||
        catalog == null ||
        settings == null ||
        monitoringPort == null ||
        fileBrowser == null ||
        readyFuture == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<void>(
      future: readyFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(snapshot.error.toString()));
        }
        if (snapshot.connectionState != ConnectionState.done) {
          final isEn = settings.language == admin.SystemAdminLanguage.en;
          final strings = AppStrings(isEn ? AppLanguage.en : AppLanguage.zh);
          return Scaffold(
            body: AppSkeletonizer.zone(
              enabled: true,
              semanticsLabel: strings.admin,
              child: const AppSkeletonList(hasLeading: true, itemCount: 6),
            ),
          );
        }
        return admin.SystemAdminFeatureScope(
          module: module,
          connectionCatalog: catalog,
          settings: settings,
          monitoring: monitoringPort,
          hostKeyConfirmation: AppSystemAdminHostKeyConfirmationAdapter(
            context,
          ),
          fileBrowser: fileBrowser,
          child: widget.child,
        );
      },
    );
  }
}
