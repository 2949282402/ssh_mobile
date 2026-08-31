// ignore_for_file: prefer_initializing_formals

import 'package:feature_connection/feature_connection.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:dartssh2/dartssh2.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/ssh_host_key_policy.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/app_log_service.dart';

/// 旧 App Scope SSH/SFTP/监控服务到 Feature Runtime Port 的适配器。
final class AppConnectionRuntimeAdapter implements ConnectionRuntimePort {
  AppConnectionRuntimeAdapter({
    this.sshServiceFactory,
    this.sftpServiceFactory,
    this.monitoringServiceFactory,
  });

  final SshService Function()? sshServiceFactory;
  final SftpService Function()? sftpServiceFactory;
  final monitoring.MonitoringService Function()? monitoringServiceFactory;

  SshService? get _sshService => sshServiceFactory?.call();
  SftpService? get _sftpService => sftpServiceFactory?.call();
  monitoring.MonitoringService? get _monitoringService =>
      monitoringServiceFactory?.call();

  @override
  String? get errorMessage => _sshService?.errorMessage;

  @override
  Future<int> activeWindowCount(String connectionId) async {
    final ssh = _sshService;
    if (ssh == null) return 0;
    await ssh.ensureInitialized();
    return ssh.sessionCountForConnection(connectionId);
  }

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    final ssh = _sshService;
    if (ssh == null) return;
    await ssh.ensureInitialized();
    await ssh.disconnectSessionsForConnection(connectionId);
  }

  @override
  Future<void> cleanupConnectionResources(String connectionId) async {
    final ssh = _sshService;
    if (ssh != null) {
      await ssh.ensureInitialized();
      await ssh.disconnectSessionsForConnection(connectionId);
    }
    await _sftpService?.disconnectConnection(connectionId, forgetPath: true);
    _monitoringService?.stopForConnection(connectionId);

    // 旧缓存维护器当前没有可执行的磁盘清理逻辑，保留调用点以便后续
    // SFTP 模块迁移时接入真实 Owner，不在本 Step 改变缓存策略。
    AppSftpCacheMaintenance.clearCacheForConnection(connectionId);
  }

  @override
  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final ssh = _sshService;
    if (ssh == null) return null;
    await ssh.ensureInitialized();
    final confirmation = onUnknownHostKey == null
        ? null
        : (SshHostKeyPromptRequest request) => onUnknownHostKey(
            ConnectionHostKeyPrompt(
              connectionId: request.connectionId,
              connectionName: request.connectionName,
              host: request.host,
              port: request.port,
              username: request.username,
              algorithm: request.algorithm,
              fingerprint: request.fingerprint,
            ),
          );
    return ssh.openSession(
      connectionId,
      displayName: windowName,
      onUnknownHostKey: confirmation,
    );
  }
}

/// 旧 SSH ClientFactory 到 Feature Verification Port 的适配器。
/// 测试可注入一个等价的 ping/close 边界，避免验证契约测试依赖真实网络。
typedef AppConnectionVerificationConnector =
    Future<AppConnectionVerificationClient> Function(
      connection_core.ConnectionConfig config,
      ssh_core.SshCredentials credentials,
      ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    );

/// 连接验证所需的最小客户端行为。
abstract interface class AppConnectionVerificationClient {
  Future<void> ping();

  void close();
}

final class AppConnectionVerificationAdapter
    implements ConnectionVerificationPort {
  AppConnectionVerificationAdapter({
    required connection_core.CredentialRepository credentialRepository,
    required connection_core.HostKeyRepository hostKeyRepository,
    required AppLogService logger,
    AppConnectionVerificationConnector? connector,
  }) : _factory = ssh_core.SshClientFactory(
         credentialRepository: credentialRepository,
         hostKeyRepository: hostKeyRepository,
         logger: logger,
       ),
       _connector = connector;

  final ssh_core.SshClientFactory _factory;
  final AppConnectionVerificationConnector? _connector;

  @override
  Future<ConnectionVerificationResult> verify(
    connection_core.ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final legacyConfirmation = onUnknownHostKey == null
        ? null
        : (ssh_core.SshHostKeyPromptRequest request) =>
              onUnknownHostKey(_toFeaturePrompt(request));
    final credentials = ssh_core.SshCredentials(
      password: password,
      privateKey: privateKey,
    );
    final injectedConnector = _connector;
    final AppConnectionVerificationClient client;
    if (injectedConnector != null) {
      client = await injectedConnector(config, credentials, legacyConfirmation);
    } else {
      final sshClient = await _factory.connectClient(
        config,
        timeout: const Duration(seconds: 12),
        credentials: credentials,
        onUnknownHostKey: legacyConfirmation,
        // 验证只返回候选信任；Feature 在配置、Host Key、凭据的统一提交阶段持久化。
        persistHostKeyTrust: false,
      );
      client = _DartConnectionVerificationClient(sshClient);
    }
    try {
      await client.ping().timeout(const Duration(seconds: 8));
    } finally {
      client.close();
    }
    return ConnectionVerificationResult(
      algorithm: config.hostKeyAlgorithm,
      fingerprint: config.hostKeyFingerprint,
      trustedAt: config.hostKeyTrustedAt,
    );
  }
}

// The direct dartssh2 wrapper is a platform integration shim; its lifecycle is
// exercised by the dartssh2 package and the injected contract above.
// coverage:ignore-start
final class _DartConnectionVerificationClient
    implements AppConnectionVerificationClient {
  _DartConnectionVerificationClient(this._client);

  final SSHClient _client;

  @override
  Future<void> ping() => _client.ping();

  @override
  void close() => _client.close();
}
// coverage:ignore-end

ConnectionHostKeyPrompt _toFeaturePrompt(
  ssh_core.SshHostKeyPromptRequest prompt,
) {
  return ConnectionHostKeyPrompt(
    connectionId: prompt.connectionId,
    connectionName: prompt.connectionName,
    host: prompt.host,
    port: prompt.port,
    username: prompt.username,
    algorithm: prompt.algorithm,
    fingerprint: prompt.fingerprint,
  );
}

/// App Shell 兼容缓存清理边界；真实 SFTP Owner 迁移后再接入实现。
final class AppSftpCacheMaintenance {
  const AppSftpCacheMaintenance._();

  static void clearCacheForConnection(String connectionId) {
    // Step 06 不改变既有缓存策略；真实清理 Owner 在 SFTP 模块迁移时接入。
  }
}
