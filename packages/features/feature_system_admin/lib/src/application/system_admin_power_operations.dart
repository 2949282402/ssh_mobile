// System Admin 高风险电源操作。
//
// 电源命令单独放在扩展中，保持管理 Service 的生命周期和普通查询逻辑
// 聚焦；扩展仍在同一 library 内，因此可以复用 Service 的私有命令通道。

part of 'system_admin_service.dart';

/// 为管理 Service 提供带确认 Token 的重启和关机操作。
extension SystemAdminPowerOperations on SystemAdminService {
  SystemAdminSessionTarget _consumePowerToken(
    SystemPowerConfirmationToken token,
    SystemPowerAction expectedAction,
  ) {
    if (token.action != expectedAction) {
      throw StateError('System power confirmation token action mismatch');
    }
    if (!token.isFresh) {
      throw StateError('System power confirmation token expired');
    }
    _requireActiveLease(token.target);
    if (token.nonce.isEmpty || token.nonce.length > 128) {
      throw StateError('System power confirmation token is invalid');
    }
    final now = DateTime.now();
    _consumedPowerTokenNonces.removeWhere(
      (_, expiresAt) => !expiresAt.isAfter(now),
    );
    if (_consumedPowerTokenNonces.containsKey(token.nonce)) {
      throw StateError('System power confirmation token was already used');
    }
    if (_consumedPowerTokenNonces.length >=
        SystemAdminService.powerTokenRegistryCapacity) {
      throw StateError('System power confirmation registry is full');
    }
    _consumedPowerTokenNonces[token.nonce] = token.issuedAt.add(
      SystemPowerConfirmationToken.validity,
    );
    return token.target;
  }

  /// 在确认 Token 通过校验后执行服务器重启。
  Future<void> rebootServer(SystemPowerConfirmationToken token) async {
    final target = _consumePowerToken(token, SystemPowerAction.reboot);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv('reboot'),
      );
      if (result.exitCode != 0) {
        throw StateError('System reboot command failed.');
      }
      _logger.warning('Reboot command sent to server');
    } catch (e, stack) {
      _logger.error('Failed to reboot server', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// 在确认 Token 通过校验后执行服务器关机。
  Future<void> shutdownServer(SystemPowerConfirmationToken token) async {
    final target = _consumePowerToken(token, SystemPowerAction.shutdown);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'shutdown',
          arguments: const <String>['-h', 'now'],
        ),
      );
      if (result.exitCode != 0) {
        throw StateError('System shutdown command failed.');
      }
      _logger.warning('Shutdown command sent to server');
    } catch (e, stack) {
      _logger.error('Failed to shutdown server', error: e, stackTrace: stack);
      rethrow;
    }
  }
}
