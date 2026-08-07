// ignore_for_file: prefer_initializing_formals

import 'package:feature_connection/feature_connection.dart';
import 'package:connection_core/connection_core.dart' as connection_core;

import '../core/services/ssh_client_factory.dart';
import '../core/services/ssh_host_key_policy.dart';
import '../features/connection/services/connection_runtime_actions.dart';
import '../services/performance_monitor_service.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';

/// 旧 App Scope SSH/SFTP/监控服务到 Feature Runtime Port 的适配器。
final class AppConnectionRuntimeAdapter implements ConnectionRuntimePort {
  AppConnectionRuntimeAdapter({
    this.sshServiceFactory,
    this.sftpServiceFactory,
    this.performanceServiceFactory,
  });

  final SshService Function()? sshServiceFactory;
  final SftpService Function()? sftpServiceFactory;
  final PerformanceMonitorService Function()? performanceServiceFactory;

  SshService? get _sshService => sshServiceFactory?.call();
  SftpService? get _sftpService => sftpServiceFactory?.call();
  PerformanceMonitorService? get _performanceService =>
      performanceServiceFactory?.call();

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
    _performanceService?.stopForConnection(connectionId);

    // 旧缓存维护器当前没有可执行的磁盘清理逻辑，保留调用点以便后续
    // SFTP 模块迁移时接入真实 Owner，不在本 Step 改变缓存策略。
    SftpCacheMaintenance.clearCacheForConnection(connectionId);
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
    final legacyConfirmation = onUnknownHostKey == null
        ? null
        : (SshHostKeyPromptRequest request) =>
              onUnknownHostKey(_toFeaturePrompt(request));
    return ssh.openSession(
      connectionId,
      displayName: windowName,
      onUnknownHostKey: legacyConfirmation,
    );
  }
}

/// 旧 SSH ClientFactory 到 Feature Verification Port 的适配器。
final class AppConnectionVerificationAdapter
    implements ConnectionVerificationPort {
  AppConnectionVerificationAdapter(this._storageService);

  final StorageService _storageService;

  @override
  Future<ConnectionVerificationResult> verify(
    connection_core.ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final legacyConfirmation = onUnknownHostKey == null
        ? null
        : (SshHostKeyPromptRequest request) =>
              onUnknownHostKey(_toFeaturePrompt(request));
    final factory = SshClientFactory(_storageService);
    final client = await factory.connectClient(
      config,
      timeout: const Duration(seconds: 12),
      credentials: SshCredentials(password: password, privateKey: privateKey),
      onUnknownHostKey: legacyConfirmation,
    );
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

ConnectionHostKeyPrompt _toFeaturePrompt(SshHostKeyPromptRequest prompt) {
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
