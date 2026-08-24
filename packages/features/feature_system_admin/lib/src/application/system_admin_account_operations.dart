// System Admin 账户管理命令与输入策略。
//
// 本 part 只负责用户账户读取、创建、权限、锁定、密码、家目录和进程操作；
// 目标 generation 校验和 SSH Lease 生命周期统一留在 SystemAdminService。

part of 'system_admin_service.dart';

extension SystemAdminAccountOperations on SystemAdminService {
  Future<List<LinuxUserAccount>> getUserAccounts(
    SystemAdminSessionTarget target,
  ) async {
    try {
      const script = r'''cat /etc/passwd
echo "===STATUS==="
for u in $(cut -d: -f1 /etc/passwd); do
  passwd -S "$u" 2>/dev/null
done''';
      final result = await _runCommand(
        target,
        SystemAdminCommand.shell(script),
      );
      if (result.exitCode != 0) {
        throw StateError('The user-account query failed.');
      }
      return await compute(parseLinuxUserAccounts, result.stdout);
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to get user accounts',
        error: error,
        stackTrace: stackTrace,
      );
      return const <LinuxUserAccount>[];
    }
  }

  /// Create a new user account and set their password through stdin.
  Future<void> createUser(
    SystemAdminSessionTarget target, {
    required String username,
    required String password,
    String shell = '/bin/bash',
  }) async {
    final safeUsername = _validatedSystemAdminUsername(username);
    final safeShell = _validatedSystemAdminShell(shell);
    final passwordInput = _systemAdminPasswordInput(safeUsername, password);
    try {
      final createResult = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'useradd',
          arguments: <String>['-m', '-s', safeShell, '--', safeUsername],
        ),
      );
      if (createResult.exitCode != 0) {
        throw StateError('User creation failed.');
      }

      final passwordResult = await _runCommand(
        target,
        SystemAdminCommand.argv('chpasswd', standardInputBytes: passwordInput),
      );
      if (passwordResult.exitCode != 0) {
        await _runCommand(
          target,
          SystemAdminCommand.argv(
            'userdel',
            arguments: <String>['-r', '--', safeUsername],
          ),
        );
        throw StateError('Setting the initial password failed.');
      }
      _logger.info('Created a System Admin user account');
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to create a System Admin user account',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<bool> checkUserSudo(
    SystemAdminSessionTarget target,
    String username,
  ) async {
    final safeUsername = _validatedSystemAdminUsername(username);
    final groups = await _loadSystemAdminUserGroups(target, safeUsername);
    return groups != null && _containsSystemAdminGroup(groups);
  }

  Future<Set<String>?> _loadSystemAdminUserGroups(
    SystemAdminSessionTarget target,
    String safeUsername,
  ) async {
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv('groups', arguments: <String>[safeUsername]),
      );
      if (result.exitCode != 0) return null;
      return result.stdout
          .trim()
          .toLowerCase()
          .split(RegExp(r'[:\s]+'))
          .where((group) => group.isNotEmpty)
          .toSet();
    } catch (_) {
      return null;
    }
  }

  Future<void> setUserSudo(
    SystemAdminSessionTarget target,
    String username,
    bool grant,
  ) async {
    final safeUsername = _validatedSystemAdminUsername(username);
    try {
      if (grant) {
        await _tryCommands(target, <SystemAdminCommand>[
          SystemAdminCommand.argv(
            'usermod',
            arguments: <String>['-aG', 'sudo', '--', safeUsername],
          ),
          SystemAdminCommand.argv(
            'usermod',
            arguments: <String>['-aG', 'wheel', '--', safeUsername],
          ),
        ]);
      } else {
        await _removeSystemAdminGroups(target, safeUsername);
      }
      final groups = await _loadSystemAdminUserGroups(target, safeUsername);
      final verified =
          groups != null &&
          (grant
              ? _containsSystemAdminGroup(groups)
              : !_containsSystemAdminGroup(groups));
      if (!verified) {
        throw StateError(
          grant
              ? 'Failed to grant administrator privileges.'
              : 'Failed to revoke administrator privileges.',
        );
      }
      _logger.info(
        grant
            ? 'Granted System Admin privileges to an account'
            : 'Revoked System Admin privileges from an account',
      );
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to update System Admin account privileges',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<bool> _tryCommands(
    SystemAdminSessionTarget target,
    List<SystemAdminCommand> commands,
  ) async {
    for (final command in commands) {
      final result = await _runCommand(target, command);
      if (result.exitCode == 0) return true;
    }
    return false;
  }

  Future<void> _removeSystemAdminGroups(
    SystemAdminSessionTarget target,
    String safeUsername,
  ) async {
    for (final group in const <String>['sudo', 'wheel']) {
      final primary = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'gpasswd',
          arguments: <String>['-d', safeUsername, group],
        ),
      );
      if (primary.exitCode == 0) continue;
      await _runCommand(
        target,
        SystemAdminCommand.argv(
          'deluser',
          arguments: <String>[safeUsername, group],
        ),
      );
    }
  }

  Future<void> lockUser(SystemAdminSessionTarget target, String username) =>
      _setUserLock(target, username, lock: true);

  Future<void> unlockUser(SystemAdminSessionTarget target, String username) =>
      _setUserLock(target, username, lock: false);

  Future<void> _setUserLock(
    SystemAdminSessionTarget target,
    String username, {
    required bool lock,
  }) async {
    final safeUsername = _validatedSystemAdminUsername(username);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'usermod',
          arguments: <String>[lock ? '-L' : '-U', '--', safeUsername],
        ),
      );
      if (result.exitCode != 0) {
        throw StateError(lock ? 'Lock user failed.' : 'Unlock user failed.');
      }
      _logger.info(
        lock
            ? 'Locked a System Admin user account'
            : 'Unlocked a System Admin user account',
      );
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to update a System Admin user lock',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Change a user's password through stdin.
  Future<void> changePassword(
    SystemAdminSessionTarget target,
    String username,
    String newPassword,
  ) async {
    final safeUsername = _validatedSystemAdminUsername(username);
    final passwordInput = _systemAdminPasswordInput(safeUsername, newPassword);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv('chpasswd', standardInputBytes: passwordInput),
      );
      if (result.exitCode != 0) {
        throw StateError('Change password failed.');
      }
      _logger.info('Changed a System Admin user password');
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to change a System Admin user password',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<String> getUserHomeStorageUsage(
    SystemAdminSessionTarget target,
    String homeDir,
  ) async {
    final safeHomeDir = _validatedSystemAdminAbsolutePath(homeDir);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'du',
          arguments: <String>['-sh', '--', safeHomeDir],
        ),
      );
      if (result.exitCode == 0 && result.stdout.trim().isNotEmpty) {
        final parts = result.stdout.trim().split(RegExp(r'\s+'));
        if (parts.isNotEmpty) return parts.first;
      }
      return 'N/A';
    } catch (_) {
      return 'N/A';
    }
  }

  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(
    SystemAdminSessionTarget target,
    String username,
  ) async {
    final safeUsername = _validatedSystemAdminUsername(username);
    try {
      final result = await _runCommand(
        target,
        SystemAdminCommand.argv(
          'ps',
          arguments: <String>[
            '-u',
            safeUsername,
            '-o',
            'pid,rss,%cpu,%mem,args',
            '--no-headers',
          ],
        ),
      );
      if (result.exitCode != 0) return const <LinuxUserProcess>[];
      return await compute(parseLinuxUserProcesses, result.stdout);
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to get processes for a System Admin user',
        error: error,
        stackTrace: stackTrace,
      );
      return const <LinuxUserProcess>[];
    }
  }
}

bool _containsSystemAdminGroup(Set<String> groups) {
  return groups.contains('sudo') || groups.contains('wheel');
}

final RegExp _systemAdminUsernamePattern = RegExp(
  r'^[a-z_][a-z0-9_-]{0,30}\$?$',
);
final RegExp _systemAdminPathSegmentPattern = RegExp(r'^[A-Za-z0-9._+-]+$');

String _validatedSystemAdminUsername(String value) {
  final username = value.trim();
  if (username.length > 32 || !_systemAdminUsernamePattern.hasMatch(username)) {
    throw ArgumentError.value(value, 'username', 'is not a valid Linux user');
  }
  return username;
}

String _validatedSystemAdminShell(String value) {
  final shell = value.trim();
  if (shell.length > 256 || !shell.startsWith('/')) {
    throw ArgumentError.value(value, 'shell', 'must be an absolute path');
  }
  final segments = shell.substring(1).split('/');
  if (segments.isEmpty ||
      segments.any(
        (segment) =>
            segment.isEmpty ||
            segment == '.' ||
            segment == '..' ||
            !_systemAdminPathSegmentPattern.hasMatch(segment),
      )) {
    throw ArgumentError.value(value, 'shell', 'is not a safe executable path');
  }
  return shell;
}

String _validatedSystemAdminAbsolutePath(String value) {
  final path = value.trim();
  if (path.isEmpty ||
      path.length > 4096 ||
      !path.startsWith('/') ||
      path.contains('\u0000') ||
      path.contains('\r') ||
      path.contains('\n')) {
    throw ArgumentError.value(value, 'homeDir', 'is not a safe absolute path');
  }
  return path;
}

Uint8List _systemAdminPasswordInput(String username, String password) {
  if (password.isEmpty ||
      password.contains('\u0000') ||
      password.contains('\r') ||
      password.contains('\n')) {
    throw ArgumentError.value(
      password.length,
      'password',
      'must be a non-empty single-line value',
    );
  }
  final bytes = Uint8List.fromList(utf8.encode('$username:$password\n'));
  if (bytes.length > SystemAdminCommand.maxInputBytes) {
    throw ArgumentError.value(
      bytes.length,
      'password',
      'exceeds the System Admin input limit',
    );
  }
  return bytes;
}
