// System Admin 管理命令 Service。
//
// Service 负责管理会话、root 校验、命令编排和资源释放；连接、日志和
// Host Key 处理均通过 Port 注入，不直接创建 App Scope 基础设施。

import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

import '../domain/system_admin_models.dart';
import '../domain/system_admin_ports.dart';
import '../presentation/system_power_confirm_flow.dart';
import 'system_admin_parsers.dart';

part 'system_admin_power_operations.dart';

class SystemAdminService extends ChangeNotifier {
  /// 创建不拥有 App Shell 基础设施的管理 Service。
  SystemAdminService({required this._sshPort, required this._logger});

  final SystemAdminSshPort _sshPort;
  final SystemAdminLoggerPort _logger;

  String? _activeConnectionId;
  SystemAdminSshSessionPort? _activeSession;
  bool _isConnecting = false;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isRoot = false;

  @visibleForTesting
  Future<RemoteCommandResult> Function(String command)? runCommandOverride;

  @visibleForTesting
  Future<void> Function(String connectionId)? connectOverride;

  String? get connectionId => _activeConnectionId;
  bool get isConnecting => _isConnecting;
  bool get isConnected => _isConnected && _activeSession != null;
  String? get errorMessage => _errorMessage;
  bool get isRoot => _isRoot;

  /// Connect to the selected server and check for root privileges
  Future<void> connect(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    if (connectOverride != null) {
      await connectOverride!(connectionId);
      _activeConnectionId = connectionId;
      _isConnecting = false;
      _isConnected = true;
      _isRoot = true;
      _errorMessage = null;
      notifyListeners();
      return;
    }

    if (_activeConnectionId == connectionId &&
        _isConnected &&
        _activeSession != null) {
      return; // Already connected
    }

    _disconnectActive();

    _activeConnectionId = connectionId;
    _isConnecting = true;
    _isConnected = false;
    _errorMessage = null;
    _isRoot = false;
    notifyListeners();

    try {
      _logger.info('System Admin connecting to $connectionId...');
      final session = await _sshPort.connect(
        connectionId,
        onUnknownHostKey: onUnknownHostKey,
      );

      // Verify privilege level
      final result = await session.run(
        'id -u',
        timeout: const Duration(seconds: 10),
      );
      final uid = result.stdout.trim();
      final isRoot = uid == '0';

      if (!isRoot) {
        session.close();
        throw Exception('Insufficient privileges: Root access required');
      }

      _activeSession = session;
      _isRoot = true;
      _isConnected = true;
      _isConnecting = false;
      _logger.info('System Admin connected to $connectionId as root');
      notifyListeners();
    } catch (e, stack) {
      _isConnecting = false;
      _isConnected = false;
      _isRoot = false;
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      _logger.error(
        'System Admin connection failed to $connectionId',
        error: e,
        stackTrace: stack,
      );
      _disconnectActive(clearError: false);
      notifyListeners();
    }
  }

  /// Disconnect the active session
  void disconnect() {
    _disconnectActive();
    notifyListeners();
  }

  /// Cancel all active commands running on the server
  void cancelActiveCommands() {
    _activeSession?.cancelActiveCommands();
  }

  void _disconnectActive({bool clearError = true}) {
    cancelActiveCommands();
    _activeSession?.close();
    _activeSession = null;
    _activeConnectionId = null;
    _isConnecting = false;
    _isConnected = false;
    if (clearError) {
      _errorMessage = null;
    }
    _isRoot = false;
  }

  Future<RemoteCommandResult> _runCommand(
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (runCommandOverride != null) {
      return runCommandOverride!(command);
    }

    final session = _activeSession;
    if (session == null) {
      throw StateError('Not connected to remote server');
    }
    return session.run(command, timeout: timeout);
  }

  /// Check if the user has root privilege on the server
  Future<bool> checkRootPrivilege(String connectionId) async {
    return _isRoot;
  }

  /// Get currently active logged-in user sessions (who / w)
  Future<List<ActiveSession>> getActiveSessions(String connectionId) async {
    try {
      final result = await _runCommand('who');
      if (result.exitCode != 0) {
        throw Exception(
          'Command "who" exited with code ${result.exitCode}: ${result.stderr}',
        );
      }

      return compute(parseActiveSessions, result.stdout);
    } catch (e, stack) {
      _logger.error(
        'Failed to get active sessions',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

  /// Kill an active session (pkill -9 -t `tty`)
  Future<void> killActiveSession(String connectionId, String tty) async {
    try {
      // Remove '/dev/' prefix if present
      final cleanTty = tty.startsWith('/dev/') ? tty.substring(5) : tty;
      final result = await _runCommand('pkill -9 -t $cleanTty');
      if (result.exitCode != 0 && result.exitCode != 1) {
        // 1 means no processes matched
        throw Exception(
          'pkill failed with code ${result.exitCode}: ${result.stderr}',
        );
      }
      _logger.info('Killed session on TTY: $cleanTty');
    } catch (e, stack) {
      _logger.error(
        'Failed to kill active session',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Retrieve Linux user accounts list
  Future<List<LinuxUserAccount>> getUserAccounts(String connectionId) async {
    try {
      // We combine reading passwd and passwd status to minimize SSH connections
      final result = await _runCommand(
        'cat /etc/passwd; echo "===STATUS==="; for u in \$(cut -d: -f1 /etc/passwd); do passwd -S "\$u" 2>/dev/null; done',
      );

      if (result.exitCode != 0) {
        throw Exception('Failed to query passwd: ${result.stderr}');
      }

      return compute(parseLinuxUserAccounts, result.stdout);
    } catch (e, stack) {
      _logger.error('Failed to get user accounts', error: e, stackTrace: stack);
      return [];
    }
  }

  /// Create a new user account and set their password
  Future<void> createUser(
    String connectionId, {
    required String username,
    required String password,
    String shell = '/bin/bash',
  }) async {
    try {
      // 1. Create user with home directory and login shell
      final createResult = await _runCommand(
        'useradd -m -s "$shell" "$username"',
      );
      if (createResult.exitCode != 0) {
        throw Exception('User creation failed: ${createResult.stderr}');
      }

      // 2. Set password
      final escapedPwd = password.replaceAll("'", "'\"'\"'");
      final pwdResult = await _runCommand(
        'echo "$username:$escapedPwd" | chpasswd',
      );
      if (pwdResult.exitCode != 0) {
        // Cleanup created user to be clean
        await _runCommand('userdel -r "$username"');
        throw Exception('Setting initial password failed: ${pwdResult.stderr}');
      }

      _logger.info('Created user account: $username');
    } catch (e, stack) {
      _logger.error(
        'Failed to create user $username',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Check if user belongs to sudo or wheel group
  Future<bool> checkUserSudo(String connectionId, String username) async {
    try {
      final result = await _runCommand('groups "$username" 2>/dev/null');
      if (result.exitCode == 0) {
        final groups = result.stdout.trim().toLowerCase();
        return groups.contains('sudo') || groups.contains('wheel');
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Grant or revoke admin (sudo/wheel) privileges for a user
  Future<void> setUserSudo(
    String connectionId,
    String username,
    bool grant,
  ) async {
    try {
      if (grant) {
        // Try adding to sudo first, fall back to wheel
        final result = await _runCommand(
          'usermod -aG sudo "$username" || usermod -aG wheel "$username"',
        );
        if (result.exitCode != 0) {
          throw Exception('Failed to grant sudo: ${result.stderr}');
        }
        _logger.info('Granted sudo privileges to $username');
      } else {
        // Try removing from sudo and wheel
        final result = await _runCommand(
          'gpasswd -d "$username" sudo || gpasswd -d "$username" wheel || deluser "$username" sudo || deluser "$username" wheel',
        );
        if (result.exitCode != 0) {
          throw Exception('Failed to revoke sudo: ${result.stderr}');
        }
        _logger.info('Revoked sudo privileges from $username');
      }
    } catch (e, stack) {
      _logger.error(
        'Failed to set sudo privileges for user $username',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Lock/disable user account
  Future<void> lockUser(String connectionId, String username) async {
    try {
      final result = await _runCommand('usermod -L $username');
      if (result.exitCode != 0) {
        throw Exception('Lock user failed: ${result.stderr}');
      }
      _logger.info('Locked user account: $username');
    } catch (e, stack) {
      _logger.error(
        'Failed to lock user $username',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Unlock/enable user account
  Future<void> unlockUser(String connectionId, String username) async {
    try {
      final result = await _runCommand('usermod -U $username');
      if (result.exitCode != 0) {
        throw Exception('Unlock user failed: ${result.stderr}');
      }
      _logger.info('Unlocked user account: $username');
    } catch (e, stack) {
      _logger.error(
        'Failed to unlock user $username',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Change a user's password
  Future<void> changePassword(
    String connectionId,
    String username,
    String newPassword,
  ) async {
    try {
      // Escape single quotes for safety
      final escapedPwd = newPassword.replaceAll("'", "'\"'\"'");
      final result = await _runCommand(
        'echo \'$username:$escapedPwd\' | chpasswd',
      );
      if (result.exitCode != 0) {
        throw Exception('Change password failed: ${result.stderr}');
      }
      _logger.info('Changed password for user: $username');
    } catch (e, stack) {
      _logger.error(
        'Failed to change password for user $username',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Get storage usage of user home directory (du -sh)
  Future<String> getUserHomeStorageUsage(
    String connectionId,
    String homeDir,
  ) async {
    try {
      final result = await _runCommand('du -sh "$homeDir" 2>/dev/null');
      if (result.exitCode == 0 && result.stdout.trim().isNotEmpty) {
        final parts = result.stdout.trim().split(RegExp(r'\s+'));
        if (parts.isNotEmpty) {
          return parts[0];
        }
      }
      return 'N/A';
    } catch (e) {
      // Return N/A silently on simple errors (like home dir not existing)
      return 'N/A';
    }
  }

  /// Get processes and memory usage for a specific user
  Future<List<LinuxUserProcess>> getUserProcessesAndMemory(
    String connectionId,
    String username,
  ) async {
    try {
      final result = await _runCommand(
        'ps -u $username -o pid,rss,%cpu,%mem,args --no-headers 2>/dev/null',
      );
      if (result.exitCode != 0) {
        return [];
      }

      return compute(parseLinuxUserProcesses, result.stdout);
    } catch (e, stack) {
      _logger.error(
        'Failed to get processes for user $username',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

  /// Get running and overall systemd services
  Future<List<SystemdService>> getSystemdServices(String connectionId) async {
    try {
      final result = await _runCommand(
        'systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null',
      );
      if (result.exitCode != 0) {
        throw Exception('systemctl command failed: ${result.stderr}');
      }

      return compute(parseSystemdServices, result.stdout);
    } catch (e, stack) {
      _logger.error(
        'Failed to get systemd services',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

  /// Start/Stop/Restart/Enable/Disable systemd service
  Future<void> manageSystemdService(
    String connectionId,
    String serviceName,
    String action,
  ) async {
    try {
      // Validate action to prevent injection
      const allowedActions = {'start', 'stop', 'restart', 'enable', 'disable'};
      if (!allowedActions.contains(action)) {
        throw ArgumentError('Invalid service action: $action');
      }

      final result = await _runCommand('systemctl $action "$serviceName"');
      if (result.exitCode != 0) {
        throw Exception(
          'Failed to $action service $serviceName: ${result.stderr}',
        );
      }
      _logger.info('Performed service action: systemctl $action $serviceName');
    } catch (e, stack) {
      _logger.error(
        'Failed to perform service action $action on $serviceName',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Get system listening ports (ss -tulpn)
  Future<List<ListeningPort>> getListeningPorts(String connectionId) async {
    try {
      // Run ss -tulpn first, fallback to netstat -tulpn
      var result = await _runCommand('ss -tulpn 2>/dev/null');
      if (result.exitCode != 0 || result.stdout.trim().isEmpty) {
        result = await _runCommand('netstat -tulpn 2>/dev/null');
      }

      return compute(parseListeningPorts, result.stdout);
    } catch (e, stack) {
      _logger.error(
        'Failed to query listening ports',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

  @override
  void dispose() {
    _disconnectActive();
    super.dispose();
  }
}
