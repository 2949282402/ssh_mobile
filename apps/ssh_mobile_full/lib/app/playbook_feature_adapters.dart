// Playbook Feature 的 App Shell 适配层。
//
// AppRuntime 持有 Connection、SSH、日志和 DataProtection；本文件只把这些
// 实现转换为 Feature 的公开 Port，确保 Package 不反向依赖 App `/src/`。

import 'package:connection_core/connection_core.dart';
import 'package:feature_playbook/feature_playbook.dart' as playbook;
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/data_protection_service.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/connection_target_binding.dart';
import '../services/ssh_service.dart';

/// 将旧 AppSettings 适配为 Playbook 的最小设置 Port。
final class AppPlaybookSettingsAdapter extends ChangeNotifier
    implements playbook.PlaybookSettingsPort {
  AppPlaybookSettingsAdapter(this._settings) {
    _settings.addListener(_forwardChange);
  }

  final AppSettings _settings;
  bool _disposed = false;

  @override
  playbook.PlaybookLanguage get language => _settings.language == AppLanguage.en
      ? playbook.PlaybookLanguage.en
      : playbook.PlaybookLanguage.zh;

  @override
  bool get isEnglish => _settings.isEnglish;

  void _forwardChange() {
    if (!_disposed) notifyListeners();
  }

  /// 只解除监听，不释放 AppSettings。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(_forwardChange);
    super.dispose();
  }
}

/// 将 Connection Core 的连接目录适配为 Playbook 的只读连接目录。
final class AppPlaybookConnectionCatalogAdapter extends ChangeNotifier
    implements playbook.PlaybookConnectionCatalogPort {
  AppPlaybookConnectionCatalogAdapter(this._repository);

  final ConnectionRepository _repository;
  bool _disposed = false;

  @override
  bool get isInitialized => true;

  @override
  List<ConnectionConfig> get connections => _repository.connections;

  @override
  ConnectionConfig? connectionById(String id) => _repository.getConnection(id);

  /// 该适配器不拥有 Connection Repository，无需释放底层资源。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

/// 将旧日志实现限制为 Playbook 需要的结构化日志 Port。
final class AppPlaybookLoggerAdapter implements playbook.PlaybookLoggerPort {
  const AppPlaybookLoggerAdapter(this._logger);

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

/// 将 App 的 AES-GCM 数据保护服务适配为 Playbook Port。
final class AppPlaybookDataProtectionAdapter
    implements playbook.PlaybookDataProtectionPort {
  const AppPlaybookDataProtectionAdapter(this._dataProtection);

  final DataProtectionService _dataProtection;

  @override
  Future<String> encryptString(String plaintext) =>
      _dataProtection.encryptString(plaintext);

  @override
  Future<String> decryptString(String value) =>
      _dataProtection.decryptString(value);

  @override
  bool isEncrypted(String value) => _dataProtection.isEncrypted(value);
}

/// 将旧 SshService 的一次性命令能力适配为 Playbook Port。
final class AppPlaybookSshAdapter implements playbook.PlaybookSshPort {
  const AppPlaybookSshAdapter(this._sshService);

  final SshService _sshService;

  @override
  Future<ssh_core.RemoteCommandResult> runCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final result = await _sshService.runOneShotCommand(
      connectionId: connectionId,
      command: command,
      timeout: timeout,
    );
    return ssh_core.RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  @override
  Future<ssh_core.RemoteCommandResult> runCommandForBinding({
    required ssh_core.SshTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final result = await _sshService.runOneShotCommandForBinding(
      binding: ConnectionTargetBinding.fromConfig(binding.config),
      command: command,
      timeout: timeout,
    );
    return ssh_core.RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }
}
