// System Admin 高风险电源操作。
//
// 电源命令单独放在扩展中，保持管理 Service 的生命周期和普通查询逻辑
// 聚焦；扩展仍在同一 library 内，因此可以复用 Service 的私有命令通道。

part of 'system_admin_service.dart';

/// 为管理 Service 提供带确认 Token 的重启和关机操作。
extension SystemAdminPowerOperations on SystemAdminService {
  void _validatePowerToken(
    SystemPowerConfirmationToken token,
    SystemPowerAction expectedAction,
  ) {
    if (token.action != expectedAction) {
      throw StateError('System power confirmation token action mismatch');
    }
    if (!token.isFresh) {
      throw StateError('System power confirmation token expired');
    }
  }

  /// 在确认 Token 通过校验后执行服务器重启。
  Future<void> rebootServer(
    String connectionId,
    SystemPowerConfirmationToken token,
  ) async {
    _validatePowerToken(token, SystemPowerAction.reboot);
    try {
      await _runCommand('reboot');
      _logger.warning('Reboot command sent to server');
    } catch (e, stack) {
      _logger.error('Failed to reboot server', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// 在确认 Token 通过校验后执行服务器关机。
  Future<void> shutdownServer(
    String connectionId,
    SystemPowerConfirmationToken token,
  ) async {
    _validatePowerToken(token, SystemPowerAction.shutdown);
    try {
      await _runCommand('shutdown -h now');
      _logger.warning('Shutdown command sent to server');
    } catch (e, stack) {
      _logger.error('Failed to shutdown server', error: e, stackTrace: stack);
      rethrow;
    }
  }
}
