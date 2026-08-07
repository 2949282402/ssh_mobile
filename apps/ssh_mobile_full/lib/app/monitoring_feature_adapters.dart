// Monitoring Feature 的 App Shell 适配器。
//
// 本文件把 App Scope 的旧 SSH、连接目录、日志和前台服务转换为 Feature
// Port；适配器不拥有这些资源，最终 Owner 仍是 AppRuntime。

import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/ssh_host_key_policy.dart' as legacy_ssh;
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/background_service.dart';
import '../services/connection_target_binding.dart';
import '../services/ssh_service.dart';

/// 将旧 SshService 适配为 Monitoring 的低优先级 SSH Port。
final class AppMonitoringSshAdapter implements monitoring.MonitoringSshPort {
  /// 创建不拥有 SSH Service 的适配器。
  const AppMonitoringSshAdapter(this._sshService);

  final SshService _sshService;

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    monitoring.MonitoringRequestPriority priority =
        monitoring.MonitoringRequestPriority.low,
  }) async {
    _ensureLowPriority(priority);
    final result = await _sshService.runOneShotCommand(
      connectionId: connectionId,
      command: command,
      timeout: timeout,
      onUnknownHostKey: _toLegacyConfirmation(onUnknownHostKey),
    );
    return ssh_core.RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  @override
  Future<ssh_core.RemoteCommandResult> runOneShotCommandForBinding({
    required ssh_core.SshTargetBinding binding,
    required String command,
    required Duration timeout,
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
    monitoring.MonitoringRequestPriority priority =
        monitoring.MonitoringRequestPriority.low,
  }) async {
    _ensureLowPriority(priority);
    final legacyBinding = ConnectionTargetBinding.fromConfig(binding.config);
    final result = await _sshService.runOneShotCommandForBinding(
      binding: legacyBinding,
      command: command,
      timeout: timeout,
      onUnknownHostKey: _toLegacyConfirmation(onUnknownHostKey),
    );
    return ssh_core.RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  void _ensureLowPriority(monitoring.MonitoringRequestPriority priority) {
    if (priority != monitoring.MonitoringRequestPriority.low) {
      throw StateError('Monitoring SSH requests must use low priority.');
    }
  }
}

legacy_ssh.SshHostKeyConfirmation? _toLegacyConfirmation(
  ssh_core.SshHostKeyConfirmation? callback,
) {
  if (callback == null) return null;
  return (request) => callback(
    ssh_core.SshHostKeyPromptRequest(
      connectionId: request.connectionId,
      connectionName: request.connectionName,
      host: request.host,
      port: request.port,
      username: request.username,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
    ),
  );
}

/// 将 Connection Repository 适配为监控需要的平台查询 Port。
final class AppMonitoringConnectionCatalogAdapter
    implements monitoring.MonitoringConnectionCatalogPort {
  /// 创建不拥有 Connection Repository 的适配器。
  const AppMonitoringConnectionCatalogAdapter(this._repository);

  final connection_core.ConnectionRepository _repository;

  @override
  connection_core.ServerPlatform? serverPlatformFor(String connectionId) =>
      _repository.getConnection(connectionId)?.serverPlatform;
}

/// 将 AppLogService 适配为监控日志 Port。
final class AppMonitoringLoggerAdapter
    implements monitoring.MonitoringLoggerPort {
  /// 创建日志适配器。
  const AppMonitoringLoggerAdapter(this._logger);

  final AppLogService _logger;

  @override
  void warning(String message, {String? details}) {
    _logger.warning(message, details: details);
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    _logger.error(
      message,
      error: error,
      stackTrace: stackTrace,
      details: details,
    );
  }
}

/// 将前台服务和通知配置适配为监控后台能力。
final class AppMonitoringBackgroundAdapter
    implements monitoring.MonitoringBackgroundPort {
  /// 创建不拥有 AppSettings 或 BackgroundService 的适配器。
  const AppMonitoringBackgroundAdapter(this._settings);

  final AppSettings _settings;

  @override
  Future<void> start({required String connectionName}) {
    return BackgroundServiceManager.start(
      connectionName: connectionName,
      showConnectionName: _settings.showServerNamesInNotifications,
    );
  }
}
