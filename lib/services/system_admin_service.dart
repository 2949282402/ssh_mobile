import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/system_admin.dart';
import 'ssh_service.dart';
import '../core/services/ssh_client_factory.dart';
import 'storage_service.dart';
import 'app_log_service.dart';

class SystemAdminService extends ChangeNotifier {
  final StorageService _storageService;
  late final SshClientFactory _clientFactory =
      SshClientFactory(_storageService);

  String? _activeConnectionId;
  SSHClient? _activeClient;
  bool _isConnecting = false;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isRoot = false;

  @visibleForTesting
  Future<RemoteCommandResult> Function(String command)? runCommandOverride;

  @visibleForTesting
  Future<void> Function(String connectionId)? connectOverride;

  SystemAdminService(this._storageService);

  StorageService get storageService => _storageService;

  String? get connectionId => _activeConnectionId;
  bool get isConnecting => _isConnecting;
  bool get isConnected => _isConnected && _activeClient != null;
  String? get errorMessage => _errorMessage;
  bool get isRoot => _isRoot;

  /// Connect to the selected server and check for root privileges
  Future<void> connect(String connectionId) async {
    if (connectOverride != null) {
      await connectOverride!(connectionId);
      return;
    }

    if (_activeConnectionId == connectionId &&
        _isConnected &&
        _activeClient != null) {
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
      final config = _storageService.getConnection(connectionId);
      if (config == null) {
        throw Exception('Connection config not found');
      }

      AppLogService.instance
          .info('System Admin connecting to ${config.name}...');
      final client = await _clientFactory.connectClient(config);

      // Verify privilege level
      final result = await client
          .runWithResult('id -u')
          .timeout(const Duration(seconds: 10));
      final uid = utf8.decode(result.stdout, allowMalformed: true).trim();
      final isRoot = uid == '0';

      if (!isRoot) {
        client.close();
        throw Exception('Insufficient privileges: Root access required');
      }

      _activeClient = client;
      _isRoot = true;
      _isConnected = true;
      _isConnecting = false;
      AppLogService.instance
          .info('System Admin connected to ${config.name} as root');
      notifyListeners();
    } catch (e, stack) {
      _isConnecting = false;
      _isConnected = false;
      _isRoot = false;
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      AppLogService.instance.error(
        'System Admin connection failed to $connectionId',
        error: e,
        stackTrace: stack,
      );
      _disconnectActive();
      notifyListeners();
    }
  }

  /// Disconnect the active session
  void disconnect() {
    _disconnectActive();
    notifyListeners();
  }

  void _disconnectActive() {
    _activeClient?.close();
    _activeClient = null;
    _activeConnectionId = null;
    _isConnecting = false;
    _isConnected = false;
    _errorMessage = null;
    _isRoot = false;
  }

  Future<RemoteCommandResult> _runCommand(
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (runCommandOverride != null) {
      return runCommandOverride!(command);
    }

    final client = _activeClient;
    if (client == null) {
      throw StateError('Not connected to remote server');
    }
    final result = await client.runWithResult(command).timeout(timeout);
    return RemoteCommandResult(
      exitCode: result.exitCode,
      stdout: utf8.decode(result.stdout, allowMalformed: true),
      stderr: utf8.decode(result.stderr, allowMalformed: true),
    );
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
            'Command "who" exited with code ${result.exitCode}: ${result.stderr}');
      }

      final sessions = <ActiveSession>[];
      final lines = const LineSplitter().convert(result.stdout);
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        // Split by multiple spaces
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;

        final username = parts[0];
        final tty = parts[1];

        // loginTime is usually date + time
        String loginTime = '';
        String ipAddress = '';
        if (parts.length >= 4) {
          loginTime = '${parts[2]} ${parts[3]}';
          if (parts.length >= 5) {
            ipAddress = parts
                .sublist(4)
                .join(' ')
                .replaceAll('(', '')
                .replaceAll(')', '');
          }
        } else {
          loginTime = parts.sublist(2).join(' ');
        }

        sessions.add(ActiveSession(
          username: username,
          tty: tty,
          loginTime: loginTime,
          ipAddress: ipAddress,
        ));
      }
      return sessions;
    } catch (e, stack) {
      AppLogService.instance.error(
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
            'pkill failed with code ${result.exitCode}: ${result.stderr}');
      }
      AppLogService.instance.info('Killed session on TTY: $cleanTty');
    } catch (e, stack) {
      AppLogService.instance.error(
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
          'cat /etc/passwd; echo "===STATUS==="; for u in \$(cut -d: -f1 /etc/passwd); do passwd -S "\$u" 2>/dev/null; done');

      if (result.exitCode != 0) {
        throw Exception('Failed to query passwd: ${result.stderr}');
      }

      final parts = result.stdout.split('===STATUS===');
      final passwdText = parts[0];
      final statusText = parts.length > 1 ? parts[1] : '';

      // Parse status mapping (username -> statusChar)
      final statusMap = <String, String>{};
      final statusLines = const LineSplitter().convert(statusText);
      for (final line in statusLines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final fields = trimmed.split(RegExp(r'\s+'));
        if (fields.length >= 2) {
          final username = fields[0];
          final statusVal = fields[1]; // L, P, NP, etc.
          statusMap[username] = statusVal;
        }
      }

      final accounts = <LinuxUserAccount>[];
      final passwdLines = const LineSplitter().convert(passwdText);
      for (final line in passwdLines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        final fields = trimmed.split(':');
        if (fields.length < 7) continue;

        final username = fields[0];
        final uid = int.tryParse(fields[2]) ?? -1;
        final gid = int.tryParse(fields[3]) ?? -1;
        final homeDir = fields[5];
        final shell = fields[6];

        // Filter: We include root (uid 0) and normal users (typically uid >= 1000)
        // Also skip system users that have nologin shells or false shells unless uid >= 1000
        final isInteractiveShell = shell.isNotEmpty &&
            !shell.contains('nologin') &&
            !shell.contains('false') &&
            (shell.endsWith('sh') || shell.contains('sh'));
        if (uid == 0 || (uid >= 1000 && uid < 65534) || isInteractiveShell) {
          final status = statusMap[username] ?? 'Unknown';
          accounts.add(LinuxUserAccount(
            username: username,
            uid: uid,
            gid: gid,
            homeDir: homeDir,
            shell: shell,
            status: status,
          ));
        }
      }

      // Sort: Root first, then alphabetical by username
      accounts.sort((a, b) {
        if (a.uid == 0) return -1;
        if (b.uid == 0) return 1;
        return a.username.compareTo(b.username);
      });

      return accounts;
    } catch (e, stack) {
      AppLogService.instance.error(
        'Failed to get user accounts',
        error: e,
        stackTrace: stack,
      );
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
      final createResult =
          await _runCommand('useradd -m -s "$shell" "$username"');
      if (createResult.exitCode != 0) {
        throw Exception('User creation failed: ${createResult.stderr}');
      }

      // 2. Set password
      final escapedPwd = password.replaceAll("'", "'\"'\"'");
      final pwdResult =
          await _runCommand('echo "$username:$escapedPwd" | chpasswd');
      if (pwdResult.exitCode != 0) {
        // Cleanup created user to be clean
        await _runCommand('userdel -r "$username"');
        throw Exception('Setting initial password failed: ${pwdResult.stderr}');
      }

      AppLogService.instance.info('Created user account: $username');
    } catch (e, stack) {
      AppLogService.instance.error(
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
      String connectionId, String username, bool grant) async {
    try {
      if (grant) {
        // Try adding to sudo first, fall back to wheel
        final result = await _runCommand(
            'usermod -aG sudo "$username" || usermod -aG wheel "$username"');
        if (result.exitCode != 0) {
          throw Exception('Failed to grant sudo: ${result.stderr}');
        }
        AppLogService.instance.info('Granted sudo privileges to $username');
      } else {
        // Try removing from sudo and wheel
        final result = await _runCommand(
            'gpasswd -d "$username" sudo || gpasswd -d "$username" wheel || deluser "$username" sudo || deluser "$username" wheel');
        if (result.exitCode != 0) {
          throw Exception('Failed to revoke sudo: ${result.stderr}');
        }
        AppLogService.instance.info('Revoked sudo privileges from $username');
      }
    } catch (e, stack) {
      AppLogService.instance.error(
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
      AppLogService.instance.info('Locked user account: $username');
    } catch (e, stack) {
      AppLogService.instance.error(
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
      AppLogService.instance.info('Unlocked user account: $username');
    } catch (e, stack) {
      AppLogService.instance.error(
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
      final result =
          await _runCommand('echo \'$username:$escapedPwd\' | chpasswd');
      if (result.exitCode != 0) {
        throw Exception('Change password failed: ${result.stderr}');
      }
      AppLogService.instance.info('Changed password for user: $username');
    } catch (e, stack) {
      AppLogService.instance.error(
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
          'ps -u $username -o pid,rss,%cpu,%mem,args --no-headers 2>/dev/null');
      if (result.exitCode != 0) {
        return [];
      }

      final processes = <LinuxUserProcess>[];
      final lines = const LineSplitter().convert(result.stdout);
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length < 5) continue;

        final pid = int.tryParse(parts[0]) ?? -1;
        final rssKb = int.tryParse(parts[1]) ?? 0;
        final cpu = double.tryParse(parts[2]) ?? 0.0;
        final mem = double.tryParse(parts[3]) ?? 0.0;
        final command = parts.sublist(4).join(' ');

        processes.add(LinuxUserProcess(
          pid: pid,
          rssBytes: rssKb * 1024,
          cpuPercent: cpu,
          memPercent: mem,
          command: command,
        ));
      }

      // Sort: RSS descending
      processes.sort((a, b) => b.rssBytes.compareTo(a.rssBytes));
      return processes;
    } catch (e, stack) {
      AppLogService.instance.error(
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
          'systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null');
      if (result.exitCode != 0) {
        throw Exception('systemctl command failed: ${result.stderr}');
      }

      final services = <SystemdService>[];
      final lines = const LineSplitter().convert(result.stdout);
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        // Lines look like: ssh.service loaded active running OpenBSD Secure Shell server
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length < 4) continue;

        final name = parts[0];
        final loadState = parts[1];
        final activeState = parts[2];
        final subState = parts[3];
        final description = parts.sublist(4).join(' ');

        services.add(SystemdService(
          name: name,
          loadState: loadState,
          activeState: activeState,
          subState: subState,
          description: description,
        ));
      }
      return services;
    } catch (e, stack) {
      AppLogService.instance.error(
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
            'Failed to $action service $serviceName: ${result.stderr}');
      }
      AppLogService.instance
          .info('Performed service action: systemctl $action $serviceName');
    } catch (e, stack) {
      AppLogService.instance.error(
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

      final ports = <ListeningPort>[];
      final lines = const LineSplitter().convert(result.stdout);
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty ||
            trimmed.startsWith('Netid') ||
            trimmed.startsWith('Active')) {
          continue;
        }

        // Split line fields
        final fields = trimmed.split(RegExp(r'\s+'));
        if (fields.length < 5) continue;

        final protocol = fields[0];

        // Extract local address and port dynamically based on command output format (ss vs netstat)
        // ss has state at index 1 ("LISTEN" / "UNCONN"), while netstat has numeric Queue size.
        final isNetstat = fields.length > 2 && int.tryParse(fields[1]) != null;
        final localAddrIndex = isNetstat ? 3 : 4;

        if (fields.length <= localAddrIndex) continue;
        final localAddressFull =
            fields[localAddrIndex]; // e.g. 0.0.0.0:22 or [::]:22 or *:22
        final lastColon = localAddressFull.lastIndexOf(':');
        if (lastColon == -1) continue;

        final localAddress = localAddressFull.substring(0, lastColon);
        final localPortStr = localAddressFull.substring(lastColon + 1);
        final localPort = int.tryParse(localPortStr) ?? 0;

        // Extract process details if present
        String processName = '-';
        int? pid;

        // In ss -tulpn, process info is in the last field: users:(("sshd",pid=1024,fd=3))
        // In netstat -tulpn, it's: 1024/sshd
        final lastField = fields.last;
        if (lastField.contains('users:')) {
          final pidRegex = RegExp(r'"([^"]+)",pid=(\d+)');
          final match = pidRegex.firstMatch(lastField);
          if (match != null) {
            processName = match.group(1) ?? '-';
            pid = int.tryParse(match.group(2) ?? '');
          }
        } else if (RegExp(r'^\d+/').hasMatch(lastField)) {
          final parts = lastField.split('/');
          pid = int.tryParse(parts[0]);
          processName = parts.sublist(1).join('/');
        }

        ports.add(ListeningPort(
          protocol: protocol,
          localAddress: localAddress,
          localPort: localPort,
          processName: processName,
          pid: pid,
        ));
      }

      // Sort: localPort ascending
      ports.sort((a, b) => a.localPort.compareTo(b.localPort));
      return ports;
    } catch (e, stack) {
      AppLogService.instance.error(
        'Failed to query listening ports',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

  /// Reboot the server
  Future<void> rebootServer(String connectionId) async {
    try {
      await _runCommand('reboot');
      AppLogService.instance.warning('Reboot command sent to server');
    } catch (e, stack) {
      AppLogService.instance.error(
        'Failed to reboot server',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Shutdown the server
  Future<void> shutdownServer(String connectionId) async {
    try {
      await _runCommand('shutdown -h now');
      AppLogService.instance.warning('Shutdown command sent to server');
    } catch (e, stack) {
      AppLogService.instance.error(
        'Failed to shutdown server',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  @override
  void dispose() {
    _disconnectActive();
    super.dispose();
  }
}
