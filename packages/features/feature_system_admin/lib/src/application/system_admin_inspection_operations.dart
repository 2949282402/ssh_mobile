// System Admin 会话、服务和端口检查命令。
//
// 本 part 负责只读检查及其紧邻的会话/服务操作；目标 generation 校验、
// 命令输出上限和 SSH Lease 生命周期统一留在 SystemAdminService。

part of 'system_admin_service.dart';

extension SystemAdminInspectionOperations on SystemAdminService {
  Future<List<ActiveSession>> getActiveSessions(
    SystemAdminSessionTarget target,
  ) async {
    try {
      final result = await _runCommand(target, SystemAdminCommand.argv('who'));
      if (result.exitCode != 0) {
        throw StateError(
          'The active-session query failed with exit code ${result.exitCode}.',
        );
      }
      return await compute(parseActiveSessions, result.stdout);
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to get active sessions',
        error: error,
        stackTrace: stackTrace,
      );
      return const <ActiveSession>[];
    }
  }

  Future<void> killActiveSession(
    SystemAdminSessionTarget target,
    String tty,
  ) async {
    final cleanTty = _validatedSystemAdminTty(tty);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'pkill',
          arguments: <String>['-9', '-t', cleanTty],
        ),
      );
      if (result.exitCode != 0 && result.exitCode != 1) {
        throw StateError(
          'The session termination command failed with exit code '
          '${result.exitCode}.',
        );
      }
      _logger.info('Killed a System Admin session');
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to kill active session',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<SystemdService>> getSystemdServices(
    SystemAdminSessionTarget target,
  ) async {
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'systemctl',
          arguments: const <String>[
            'list-units',
            '--type=service',
            '--all',
            '--no-pager',
            '--no-legend',
          ],
        ),
      );
      if (result.exitCode != 0) {
        throw StateError('The system-service query failed.');
      }
      return await compute(parseSystemdServices, result.stdout);
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to get systemd services',
        error: error,
        stackTrace: stackTrace,
      );
      return const <SystemdService>[];
    }
  }

  Future<void> manageSystemdService(
    SystemAdminSessionTarget target,
    String serviceName,
    String action,
  ) async {
    const allowedActions = <String>{
      'start',
      'stop',
      'restart',
      'enable',
      'disable',
    };
    if (!allowedActions.contains(action)) {
      throw ArgumentError.value(action, 'action', 'is not allowed');
    }
    final safeServiceName = _validatedSystemAdminServiceName(serviceName);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'systemctl',
          arguments: <String>[action, '--', safeServiceName],
        ),
      );
      if (result.exitCode != 0) {
        throw StateError('Failed to perform the requested service action.');
      }
      _logger.info('Performed an approved systemd service action');
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to perform an approved systemd service action',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<ListeningPort>> getListeningPorts(
    SystemAdminSessionTarget target,
  ) async {
    try {
      var result = await _runCommand(
        target,
        SystemAdminCommand.argv('ss', arguments: const <String>['-tulpn']),
      );
      if (result.exitCode != 0 || result.stdout.trim().isEmpty) {
        result = await _runCommand(
          target,
          SystemAdminCommand.argv(
            'netstat',
            arguments: const <String>['-tulpn'],
          ),
        );
      }
      return await compute(parseListeningPorts, result.stdout);
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to query listening ports',
        error: error,
        stackTrace: stackTrace,
      );
      return const <ListeningPort>[];
    }
  }
}

final RegExp _systemAdminTtyPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$');

String _validatedSystemAdminTty(String value) {
  final tty = value.startsWith('/dev/') ? value.substring(5) : value;
  if (tty.isEmpty ||
      tty.length > 128 ||
      !_systemAdminTtyPattern.hasMatch(tty) ||
      tty.contains('..') ||
      tty.contains('//')) {
    throw ArgumentError.value(value, 'tty', 'is not a valid terminal name');
  }
  return tty;
}

String _validatedSystemAdminServiceName(String value) {
  final serviceName = value.trim();
  if (serviceName.isEmpty ||
      serviceName.length > 256 ||
      serviceName.contains('\u0000') ||
      serviceName.contains('\r') ||
      serviceName.contains('\n')) {
    throw ArgumentError.value(
      value,
      'serviceName',
      'contains invalid characters',
    );
  }
  return serviceName;
}
