// System Admin Feature 的 App Shell 适配器。
//
// App Shell 负责把旧 Storage/SFTP、App 文案和 Runtime Monitoring 转换为
// Feature Port。适配器本身不拥有 App Scope 的 SSH、SFTP 或 Monitoring；
// Route Scope 只拥有 SystemAdminModule 创建的管理会话。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:dartssh2/dartssh2.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/ssh_host_key_policy.dart' as legacy_ssh;
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/remote_command_decoder.dart';
import '../services/sftp_service.dart';
import '../widgets/ssh_host_key_trust_dialog.dart';
import 'app_runtime.dart';

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

  @override
  void dispose() {
    super.dispose();
  }
}

/// 将旧 AppSettings/AppStrings 适配为 Feature 的最小设置 Port。
final class AppSystemAdminSettingsAdapter extends ChangeNotifier
    implements admin.SystemAdminSettingsPort {
  /// 创建不拥有 AppSettings 的设置适配器。
  AppSystemAdminSettingsAdapter(this._settings) {
    _settings.addListener(notifyListeners);
  }

  final AppSettings _settings;

  @override
  admin.SystemAdminLanguage get language => _settings.language == AppLanguage.en
      ? admin.SystemAdminLanguage.en
      : admin.SystemAdminLanguage.zh;

  @override
  bool get isEnglish => language == admin.SystemAdminLanguage.en;

  @override
  admin.SystemAdminStrings get strings =>
      AppSystemAdminStrings(AppStrings(_settings.language));

  @override
  void dispose() {
    _settings.removeListener(notifyListeners);
    super.dispose();
  }
}

/// Feature 文案到全局 AppStrings 的只读映射。
final class AppSystemAdminStrings implements admin.SystemAdminStrings {
  /// 创建一份语言快照；不持有设置或其它资源。
  const AppSystemAdminStrings(this._strings);

  final AppStrings _strings;

  @override
  admin.SystemAdminLanguage get language => _strings.language == AppLanguage.en
      ? admin.SystemAdminLanguage.en
      : admin.SystemAdminLanguage.zh;

  @override
  String get activeProcesses => _strings.activeProcesses;
  @override
  String get activeSessions => _strings.activeSessions;
  @override
  String get actionConfirm => _strings.actionConfirm;
  @override
  String get addConnection => _strings.addConnection;
  @override
  String get adminConnectAsRoot => _strings.adminConnectAsRoot;
  @override
  String get adminConnectionFailed => _strings.adminConnectionFailed;
  @override
  String get adminLinuxManagementHint => _strings.adminLinuxManagementHint;
  @override
  String get adminRootAccess => _strings.adminRootAccess;
  @override
  String get adminSelectServer => _strings.adminSelectServer;
  @override
  String get administrator => _strings.administrator;
  @override
  String get applications => _strings.applications;
  @override
  String get backToHome => _strings.backToHome;
  @override
  String get cancel => _strings.cancel;
  @override
  String get changePassword => _strings.changePassword;
  @override
  String get changePasswordTitle => _strings.changePasswordTitle;
  @override
  String get close => _strings.close;
  @override
  String get collapseServerList => _strings.collapseServerList;
  @override
  String get connected => _strings.connected;
  @override
  String get connectingEllipsis => _strings.connectingEllipsis;
  @override
  String get createUser => _strings.createUser;
  @override
  String get enterNewPassword => _strings.enterNewPassword;
  @override
  String get expandServerList => _strings.expandServerList;
  @override
  String get grantSudo => _strings.grantSudo;
  @override
  String get killAction => _strings.killAction;
  @override
  String get killSession => _strings.killSession;
  @override
  String killSessionConfirm(String username, String tty) =>
      _strings.killSessionConfirm(username, tty);
  @override
  String get listeningPorts => _strings.listeningPorts;
  @override
  String get lockUser => _strings.lockUser;
  @override
  String get loginShell => _strings.loginShell;
  @override
  String get memoryUsed => _strings.memoryUsed;
  @override
  String get monitor => _strings.monitor;
  @override
  String get noConnections => _strings.noConnections;
  @override
  String get normalUser => _strings.normalUser;
  @override
  String get notConnected => _strings.notConnected;
  @override
  String get nonLinuxMsg => _strings.nonLinuxMsg;
  @override
  String get omServers => _strings.omServers;
  @override
  String get passwordChangedSuccess => _strings.passwordChangedSuccess;
  @override
  String get refresh => _strings.refresh;
  @override
  String get reorderServer => _strings.reorderServer;
  @override
  String get reconnectAsRootMsg => _strings.reconnectAsRootMsg;
  @override
  String get rebootServer => _strings.rebootServer;
  @override
  String get revokeSudo => _strings.revokeSudo;
  @override
  String get rootRequiredMsg => _strings.rootRequiredMsg;
  @override
  String get save => _strings.save;
  @override
  String get searchService => _strings.searchService;
  @override
  String get selectServerToManage => _strings.selectServerToManage;
  @override
  String get serviceDisable => _strings.serviceDisable;
  @override
  String get serviceEnable => _strings.serviceEnable;
  @override
  String get serviceRestart => _strings.serviceRestart;
  @override
  String get serviceStart => _strings.serviceStart;
  @override
  String get serviceStop => _strings.serviceStop;
  @override
  String get shutdownServer => _strings.shutdownServer;
  @override
  String get statusLocked => _strings.statusLocked;
  @override
  String get storageUsed => _strings.storageUsed;
  @override
  String get sudoStatus => _strings.sudoStatus;
  @override
  String get systemOmAdmin => _strings.systemOmAdmin;
  @override
  String get systemPower => _strings.systemPower;
  @override
  String get systemPowerHint => _strings.systemPowerHint;
  @override
  String get systemServices => _strings.systemServices;
  @override
  String get unlockUser => _strings.unlockUser;
  @override
  String get usageStats => _strings.usageStats;
  @override
  String get userAccounts => _strings.userAccounts;
  @override
  String get userCreatedSuccess => _strings.userCreatedSuccess;
  @override
  String get username => _strings.username;
  @override
  String get verifyingPrivilege => _strings.verifyingPrivilege;
  @override
  String get viewHomeDir => _strings.viewHomeDir;
}

/// 将旧系统管理 SSH Client 转换为不暴露 dartssh2 的 Feature Port。
final class AppSystemAdminSshAdapter implements admin.SystemAdminSshPort {
  /// 创建不拥有 Connection、Credential、Host Key Repository 或 SSH Client
  /// 的连接适配器。
  AppSystemAdminSshAdapter({
    required connection_core.ConnectionRepository connectionRepository,
    required connection_core.CredentialRepository credentialRepository,
    required connection_core.HostKeyRepository hostKeyRepository,
    required AppLogService logger,
  }) : _connectionRepository = connectionRepository,
       _clientFactory = ssh_core.SshClientFactory(
         credentialRepository: credentialRepository,
         hostKeyRepository: hostKeyRepository,
         logger: logger,
       );

  final connection_core.ConnectionRepository _connectionRepository;
  final ssh_core.SshClientFactory _clientFactory;

  @override
  Future<admin.SystemAdminSshSessionPort> connect(
    String connectionId, {
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final config = _connectionRepository.getConnection(connectionId);
    if (config == null) throw StateError('Connection config not found');
    final client = await _clientFactory.connectClient(
      config,
      onUnknownHostKey: onUnknownHostKey,
    );
    return _AppSystemAdminSshSession(client);
  }
}

final class _AppSystemAdminSshSession
    implements admin.SystemAdminSshSessionPort {
  _AppSystemAdminSshSession(this._client);

  final SSHClient _client;
  final List<SSHSession> _activeSessions = [];
  bool _closed = false;

  @override
  Future<ssh_core.RemoteCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    if (_closed) throw StateError('System Admin SSH session is closed');
    final session = await _client.execute(command);
    _activeSessions.add(session);
    try {
      final stdoutBytes = <int>[];
      final stderrBytes = <int>[];
      await Future.wait([
        session.stdout.forEach(stdoutBytes.addAll),
        session.stderr.forEach(stderrBytes.addAll),
      ]).timeout(timeout);
      final decoded = await decodeRemoteCommandBytes(
        stdout: stdoutBytes,
        stderr: stderrBytes,
      );
      return ssh_core.RemoteCommandResult(
        exitCode: session.exitCode ?? 0,
        stdout: decoded.stdout,
        stderr: decoded.stderr,
      );
    } finally {
      _activeSessions.remove(session);
      session.close();
    }
  }

  @override
  void cancelActiveCommands() {
    for (final session in List<SSHSession>.from(_activeSessions)) {
      try {
        session.close();
      } catch (_) {
        // 取消阶段必须继续处理其它命令；底层 close 的异常不能阻断释放。
      }
    }
    _activeSessions.clear();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    cancelActiveCommands();
    _client.close();
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

/// Stateful Route Scope；Module 是本 Scope 的唯一管理服务 Owner。
final class AppSystemAdminModuleScope extends StatefulWidget {
  /// 创建 System Admin 页面 Scope。
  const AppSystemAdminModuleScope({super.key, required this.child});

  final Widget child;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_module != null) return;

    final runtime = context.read<AppRuntime>();
    _catalog = AppSystemAdminConnectionCatalogAdapter(
      runtime.connectionRepository,
    );
    _settings = AppSystemAdminSettingsAdapter(runtime.appSettings);
    _monitoring = AppSystemAdminMonitoringAdapter(runtime.monitoringService);
    _fileBrowser = AppSystemAdminFileBrowserAdapter(runtime.sftpService);
    final module = admin.SystemAdminModule();
    _module = module;
    _readyFuture = _initializeModule(module, runtime);
  }

  Future<void> _initializeModule(
    admin.SystemAdminModule module,
    AppRuntime runtime,
  ) async {
    await module.register(
      ModuleContext.fromMap({
        admin.SystemAdminSshPort: AppSystemAdminSshAdapter(
          connectionRepository: runtime.connectionRepository,
          credentialRepository: runtime.credentialRepository,
          hostKeyRepository: runtime.hostKeyRepository,
          logger: runtime.appLogService,
        ),
        admin.SystemAdminLoggerPort: AppSystemAdminLoggerAdapter(
          runtime.appLogService,
        ),
      }),
    );
    await module.activate();
  }

  @override
  void dispose() {
    final module = _module;
    if (module != null) unawaited(module.dispose());
    _catalog?.dispose();
    _settings?.dispose();
    _monitoring?.dispose();
    _module = null;
    super.dispose();
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
          return const Center(child: CircularProgressIndicator());
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
