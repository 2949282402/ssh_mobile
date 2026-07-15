import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/system_admin.dart';
import '../widgets/system_power_confirm_flow.dart';
import 'ssh_service.dart';
import '../core/services/ssh_client_factory.dart';
import '../core/services/ssh_host_key_policy.dart';
import 'storage_service.dart';
import 'app_log_service.dart';
import 'remote_command_decoder.dart';

class SystemAdminService extends ChangeNotifier {
  final StorageService _storageService;
  late final SshClientFactory _clientFactory = SshClientFactory(
    _storageService,
  );

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

      AppLogService.instance.info(
        'System Admin connecting to ${config.name}...',
      );
      final client = await _clientFactory.connectClient(
        config,
        onUnknownHostKey: onUnknownHostKey,
      );

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
      AppLogService.instance.info(
        'System Admin connected to ${config.name} as root',
      );
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
      _disconnectActive(clearError: false);
      notifyListeners();
    }
  }

  /// Disconnect the active session
  void disconnect() {
    _disconnectActive();
    notifyListeners();
  }

  final List<SSHSession> _activeSessionsList = [];

  /// Cancel all active commands running on the server
  void cancelActiveCommands() {
    for (final session in List<SSHSession>.from(_activeSessionsList)) {
      try {
        session.close();
      } catch (_) {}
    }
    _activeSessionsList.clear();
  }

  void _disconnectActive({bool clearError = true}) {
    cancelActiveCommands();
    _activeClient?.close();
    _activeClient = null;
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

    final client = _activeClient;
    if (client == null) {
      throw StateError('Not connected to remote server');
    }

    final session = await client.execute(command);
    _activeSessionsList.add(session);

    try {
      final stdoutBytes = <int>[];
      final stderrBytes = <int>[];

      final stdoutFuture = session.stdout.forEach(stdoutBytes.addAll);
      final stderrFuture = session.stderr.forEach(stderrBytes.addAll);

      await Future.wait([stdoutFuture, stderrFuture]).timeout(timeout);
      final exitCode = session.exitCode;
      final decoded = await decodeRemoteCommandBytes(
        stdout: stdoutBytes,
        stderr: stderrBytes,
      );

      return RemoteCommandResult(
        exitCode: exitCode ?? 0,
        stdout: decoded.stdout,
        stderr: decoded.stderr,
      );
    } finally {
      _activeSessionsList.remove(session);
      session.close();
    }
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

      return compute(_parseActiveSessions, result.stdout);
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
          'pkill failed with code ${result.exitCode}: ${result.stderr}',
        );
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
        'cat /etc/passwd; echo "===STATUS==="; for u in \$(cut -d: -f1 /etc/passwd); do passwd -S "\$u" 2>/dev/null; done',
      );

      if (result.exitCode != 0) {
        throw Exception('Failed to query passwd: ${result.stderr}');
      }

      return compute(_parseLinuxUserAccounts, result.stdout);
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
        AppLogService.instance.info('Granted sudo privileges to $username');
      } else {
        // Try removing from sudo and wheel
        final result = await _runCommand(
          'gpasswd -d "$username" sudo || gpasswd -d "$username" wheel || deluser "$username" sudo || deluser "$username" wheel',
        );
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
      final result = await _runCommand(
        'echo \'$username:$escapedPwd\' | chpasswd',
      );
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
        'ps -u $username -o pid,rss,%cpu,%mem,args --no-headers 2>/dev/null',
      );
      if (result.exitCode != 0) {
        return [];
      }

      return compute(_parseLinuxUserProcesses, result.stdout);
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
        'systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null',
      );
      if (result.exitCode != 0) {
        throw Exception('systemctl command failed: ${result.stderr}');
      }

      return compute(_parseSystemdServices, result.stdout);
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
          'Failed to $action service $serviceName: ${result.stderr}',
        );
      }
      AppLogService.instance.info(
        'Performed service action: systemctl $action $serviceName',
      );
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

      return compute(_parseListeningPorts, result.stdout);
    } catch (e, stack) {
      AppLogService.instance.error(
        'Failed to query listening ports',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

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

  /// Reboot the server
  Future<void> rebootServer(
    String connectionId,
    SystemPowerConfirmationToken token,
  ) async {
    _validatePowerToken(token, SystemPowerAction.reboot);
    try {
      // UI callers must complete confirmSystemPowerAction before reaching this
      // service-level execution path.
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
  Future<void> shutdownServer(
    String connectionId,
    SystemPowerConfirmationToken token,
  ) async {
    _validatePowerToken(token, SystemPowerAction.shutdown);
    try {
      // UI callers must complete confirmSystemPowerAction before reaching this
      // service-level execution path.
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

List<ActiveSession> _parseActiveSessions(String text) {
  final sessions = <ActiveSession>[];
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts.first.isEmpty) continue;
    var loginTime = '';
    var ipAddress = '';
    if (parts.length >= 4) {
      loginTime = '${parts[2]} ${parts[3]}';
      if (parts.length >= 5) {
        ipAddress = parts.sublist(4).join(' ').replaceAll(RegExp(r'[()]'), '');
      }
    } else if (parts.length > 2) {
      loginTime = parts.sublist(2).join(' ');
    }
    sessions.add(
      ActiveSession(
        username: parts[0],
        tty: parts[1],
        loginTime: loginTime,
        ipAddress: ipAddress,
      ),
    );
  }
  return sessions;
}

List<LinuxUserAccount> _parseLinuxUserAccounts(String text) {
  final sections = text.split('===STATUS===');
  final statusMap = <String, String>{};
  if (sections.length > 1) {
    for (final line in const LineSplitter().convert(sections[1])) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 2 && fields.first.isNotEmpty) {
        statusMap[fields[0]] = fields[1];
      }
    }
  }

  final accounts = <LinuxUserAccount>[];
  for (final line in const LineSplitter().convert(sections.first)) {
    final fields = line.trim().split(':');
    if (fields.length < 7 || fields.first.isEmpty) continue;
    final uid = int.tryParse(fields[2]) ?? -1;
    final gid = int.tryParse(fields[3]) ?? -1;
    final shell = fields[6];
    final isInteractiveShell =
        shell.isNotEmpty &&
        !shell.contains('nologin') &&
        !shell.contains('false') &&
        (shell.endsWith('sh') || shell.contains('sh'));
    if (uid == 0 || (uid >= 1000 && uid < 65534) || isInteractiveShell) {
      accounts.add(
        LinuxUserAccount(
          username: fields[0],
          uid: uid,
          gid: gid,
          homeDir: fields[5],
          shell: shell,
          status: statusMap[fields[0]] ?? 'Unknown',
        ),
      );
    }
  }
  accounts.sort((a, b) {
    if (a.uid == 0) return -1;
    if (b.uid == 0) return 1;
    return a.username.compareTo(b.username);
  });
  return accounts;
}

List<LinuxUserProcess> _parseLinuxUserProcesses(String text) {
  final processes = <LinuxUserProcess>[];
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 5 || parts.first.isEmpty) continue;
    processes.add(
      LinuxUserProcess(
        pid: int.tryParse(parts[0]) ?? -1,
        rssBytes: (int.tryParse(parts[1]) ?? 0) * 1024,
        cpuPercent: double.tryParse(parts[2]) ?? 0,
        memPercent: double.tryParse(parts[3]) ?? 0,
        command: parts.sublist(4).join(' '),
      ),
    );
  }
  processes.sort((a, b) => b.rssBytes.compareTo(a.rssBytes));
  return processes;
}

List<SystemdService> _parseSystemdServices(String text) {
  final services = <SystemdService>[];
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 4 || parts.first.isEmpty) continue;
    services.add(
      SystemdService(
        name: parts[0],
        loadState: parts[1],
        activeState: parts[2],
        subState: parts[3],
        description: parts.length > 4 ? parts.sublist(4).join(' ') : '',
      ),
    );
  }
  return services;
}

List<ListeningPort> _parseListeningPorts(String text) {
  final ports = <ListeningPort>[];
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('Netid') ||
        trimmed.startsWith('Active')) {
      continue;
    }
    final fields = trimmed.split(RegExp(r'\s+'));
    if (fields.length < 5) continue;
    final isNetstat = int.tryParse(fields[1]) != null;
    final localAddressIndex = isNetstat ? 3 : 4;
    if (fields.length <= localAddressIndex) continue;
    final address = fields[localAddressIndex];
    final lastColon = address.lastIndexOf(':');
    if (lastColon < 0) continue;

    var processName = '-';
    int? pid;
    final processField = fields.last;
    if (processField.contains('users:')) {
      final match = RegExp(r'"([^"]+)",pid=(\d+)').firstMatch(processField);
      if (match != null) {
        processName = match.group(1) ?? '-';
        pid = int.tryParse(match.group(2) ?? '');
      }
    } else if (RegExp(r'^\d+/').hasMatch(processField)) {
      final processParts = processField.split('/');
      pid = int.tryParse(processParts[0]);
      processName = processParts.sublist(1).join('/');
    }
    ports.add(
      ListeningPort(
        protocol: fields[0],
        localAddress: address.substring(0, lastColon),
        localPort: int.tryParse(address.substring(lastColon + 1)) ?? 0,
        processName: processName,
        pid: pid,
      ),
    );
  }
  ports.sort((a, b) => a.localPort.compareTo(b.localPort));
  return ports;
}
