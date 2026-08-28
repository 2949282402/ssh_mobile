part of 'test_storage_adapter.dart';

/// 创建使用测试夹具中显式 Repository 的旧 App SSH 服务。
SshService createTestSshService(
  TestStorageAdapter storage, {
  AppSettings? appSettings,
  TelemetryClient? telemetryClient,
  ssh_core.SshNativeStreamConnector? nativeStreamConnector,
  ssh_core.SshPeerIdResolver? peerIdResolver,
}) => SshService(
  connectionRepository: storage.connectionRepository,
  credentialRepository: storage.credentialRepository,
  hostKeyRepository: storage.hostKeyRepository,
  terminalMetadataStore: storage.terminalMetadataStore,
  appSettings: appSettings,
  telemetryClient: telemetryClient,
  nativeStreamConnector: nativeStreamConnector,
  peerIdResolver: peerIdResolver,
);

/// 创建使用测试夹具中显式 Repository 的旧 App SFTP 服务。
SftpService createTestSftpService(
  TestStorageAdapter storage, {
  SftpPathHistoryStore? pathHistoryStore,
  TelemetryClient? telemetryClient,
}) => SftpService(
  connectionRepository: storage.connectionRepository,
  credentialRepository: storage.credentialRepository,
  hostKeyRepository: storage.hostKeyRepository,
  pathHistoryStore: pathHistoryStore ?? storage.sftpPathHistory,
  telemetryClient: telemetryClient,
);

/// 创建使用测试夹具中显式 Ports 的 Monitoring Feature 服务。
monitoring.MonitoringService createTestPerformanceMonitorService(
  SshService sshService,
  TestStorageAdapter storage, {
  AppSettings? appSettings,
}) => monitoring.MonitoringService(
  sshPort: AppMonitoringSshAdapter(sshService),
  connectionCatalog: AppMonitoringConnectionCatalogAdapter(
    storage.connectionRepository,
  ),
  logger: const _TestMonitoringLogger(),
  background: appSettings == null
      ? null
      : AppMonitoringBackgroundAdapter(appSettings),
);

final class _TestMonitoringLogger implements monitoring.MonitoringLoggerPort {
  const _TestMonitoringLogger();

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

/// 创建使用显式 Feature Ports 的 Playbook Service。
playbook.PlaybookService createTestPlaybook({
  required playbook.PlaybookRepository repository,
  required SshService sshService,
}) => playbook.PlaybookService(
  repository: repository,
  sshPort: AppPlaybookSshAdapter(sshService),
  logger: const _TestPlaybookLogger(),
);

final class _TestPlaybookLogger implements playbook.PlaybookLoggerPort {
  const _TestPlaybookLogger();

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}
