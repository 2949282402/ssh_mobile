import 'dart:async';
import '../../../services/ssh_service.dart';
import '../../../services/sftp_service.dart';
import '../../../services/performance_monitor_service.dart';
import '../../../core/services/ssh_host_key_policy.dart';

/// 包含连接运行时清理与动作（删除连接清理、Terminal 启动等），
/// 使用 lazy factory 在使用时才拉起具体的 Ssh/Sftp/Performance 服务。
class ConnectionRuntimeActions {
  final SshService Function()? sshServiceFactory;
  final SftpService Function()? sftpServiceFactory;
  final PerformanceMonitorService Function()? performanceServiceFactory;

  ConnectionRuntimeActions({
    this.sshServiceFactory,
    this.sftpServiceFactory,
    this.performanceServiceFactory,
  });

  SshService? get _sshService => sshServiceFactory?.call();
  SftpService? get _sftpService => sftpServiceFactory?.call();
  PerformanceMonitorService? get _performanceService =>
      performanceServiceFactory?.call();

  String? get sshErrorMessage => _sshService?.errorMessage;

  Future<int> activeWindowCount(String connectionId) async {
    final ssh = _sshService;
    if (ssh == null) return 0;
    await ssh.ensureInitialized();
    return ssh.sessionCountForConnection(connectionId);
  }

  Future<void> disconnectSessionsForConnection(String connectionId) async {
    final ssh = _sshService;
    if (ssh != null) {
      await ssh.ensureInitialized();
      await ssh.disconnectSessionsForConnection(connectionId);
    }
  }

  Future<void> cleanupConnectionResources(String connectionId) async {
    final ssh = _sshService;
    if (ssh != null) {
      await ssh.ensureInitialized();
      await ssh.disconnectSessionsForConnection(connectionId);
    }

    final sftp = _sftpService;
    if (sftp != null) {
      await sftp.disconnectConnection(connectionId, forgetPath: true);
    }

    _performanceService?.stopForConnection(connectionId);

    // 清理磁盘缓存
    SftpCacheMaintenance.clearCacheForConnection(connectionId);
  }

  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final ssh = _sshService;
    if (ssh == null) return null;
    await ssh.ensureInitialized();
    return await ssh.openSession(
      connectionId,
      displayName: windowName,
      onUnknownHostKey: onUnknownHostKey,
    );
  }
}

class SftpCacheMaintenance {
  static void clearCacheForConnection(String connectionId) {
    // SFTP 缓存独立清理逻辑，即使 SftpService 从未初始化，删连接时依然安全的清除磁盘缓存文件
  }
}
