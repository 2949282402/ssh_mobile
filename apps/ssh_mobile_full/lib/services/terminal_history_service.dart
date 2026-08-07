// Terminal 原始输出历史服务的旧 App 路径兼容 facade。
//
// 实现已迁移到 feature_terminal；此处只注入 App 的数据保护和日志能力，
// 保留 SshService 现有构造调用面，避免一次性改动无关的 SSH 业务代码。

import 'package:feature_terminal/feature_terminal.dart' as feature_terminal;

import '../core/services/data_protection_service.dart';
import 'app_log_service.dart';

/// 旧路径下的 TerminalHistoryService 兼容类型。
class TerminalHistoryService extends feature_terminal.TerminalHistoryService {
  /// 使用 App Scope 的安全和日志 Owner 创建迁移后的服务。
  TerminalHistoryService()
    : super(
        dataProtection: _AppTerminalHistoryProtector(),
        logger: _AppTerminalHistoryLogger(),
      );
}

final class _AppTerminalHistoryProtector
    implements feature_terminal.TerminalHistoryOutputProtector {
  final DataProtectionService _service = DataProtectionService.instance;

  @override
  String get encryptedPrefix => DataProtectionService.encryptedPrefix;

  @override
  bool isEncrypted(String value) => _service.isEncrypted(value);

  @override
  Future<String> encryptString(String value) => _service.encryptString(value);

  @override
  Future<String> decryptString(String value) => _service.decryptString(value);
}

final class _AppTerminalHistoryLogger
    implements feature_terminal.TerminalLoggerPort {
  final AppLogService _service = AppLogService.instance;

  @override
  void info(String message) => _service.info(message);

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) {
    _service.warning(
      message,
      details: error == null ? null : '$error\n$stackTrace',
    );
  }

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) {
    _service.error(message, error: error, stackTrace: stackTrace);
  }
}
