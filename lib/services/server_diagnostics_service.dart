import 'dart:convert';

import 'server_status_probe.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

abstract interface class ServerDiagnosticsAdapter {
  Future<Map<String, dynamic>> detectOs(String connectionId);

  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  });

  Future<Map<String, dynamic>> generateOpsReport(String connectionId);
}

class ServerDiagnosticsService implements ServerDiagnosticsAdapter {
  final StorageService storageService;
  final SshClientAdapter sshService;

  const ServerDiagnosticsService({
    required this.storageService,
    required this.sshService,
  });

  @override
  Future<Map<String, dynamic>> detectOs(String connectionId) {
    return _detectRemoteOs(connectionId);
  }

  @override
  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  }) async {
    final normalizedMode = mode?.trim().toLowerCase();
    final os = await _detectRemoteOs(connectionId);
    if (os['os'] == 'windows') {
      return _windowsServerStatus(connectionId, normalizedMode, os);
    }

    final wantPerformance =
        normalizedMode == null ||
        normalizedMode.isEmpty ||
        normalizedMode == 'all' ||
        normalizedMode == 'performance';
    final wantPorts =
        normalizedMode == null ||
        normalizedMode.isEmpty ||
        normalizedMode == 'all' ||
        normalizedMode == 'ports';
    final wantApplications =
        normalizedMode == null ||
        normalizedMode.isEmpty ||
        normalizedMode == 'all' ||
        normalizedMode == 'applications' ||
        normalizedMode == 'apps';

    final payload = <String, dynamic>{'connectionId': connectionId, 'os': os};

    if (wantPerformance) {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: ServerStatusProbe.performanceCommand,
        timeout: const Duration(seconds: 12),
      );
      final raw = ServerStatusProbe.parsePerformanceOutput(result.stdout);
      payload['performance'] = {
        'memoryPercent': raw.counters.memoryPercent,
        'diskUsage': raw.diskUsage.map((item) => item.toJson()).toList(),
        'rawCounters': {
          'cpuTotal': raw.counters.cpuTotal,
          'cpuBusy': raw.counters.cpuBusy,
          'diskBytes': raw.counters.diskBytes,
          'networkBytes': raw.counters.networkBytes,
        },
        'stderr': _truncate(result.stderr),
      };
    }

    if (wantPorts) {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: ServerStatusProbe.portsCommand,
        timeout: const Duration(seconds: 12),
      );
      payload['ports'] = ServerStatusProbe.parsePorts(
        result.stdout,
      ).take(200).map((item) => item.toJson()).toList();
      if (result.stderr.trim().isNotEmpty) {
        payload['portsStderr'] = _truncate(result.stderr);
      }
    }

    if (wantApplications) {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: ServerStatusProbe.applicationsCommand,
        timeout: const Duration(seconds: 12),
      );
      payload['applications'] = ServerStatusProbe.parseApplications(
        result.stdout,
      ).map((item) => item.toJson()).toList();
      if (result.stderr.trim().isNotEmpty) {
        payload['applicationsStderr'] = _truncate(result.stderr);
      }
    }

    return payload;
  }

  @override
  Future<Map<String, dynamic>> generateOpsReport(String connectionId) async {
    final connection = storageService.getConnection(connectionId);
    final os = await _detectRemoteOs(connectionId);

    if (os['os'] == 'windows') {
      final status = await _windowsServerStatus(connectionId, 'all', os);
      return {
        'connectionId': connectionId,
        'server': connection == null
            ? null
            : {
                'name': connection.name,
                'host': connection.host,
                'port': connection.port,
                'username': connection.username,
              },
        'os': os,
        'health': {
          'level': 'unknown',
          'suggestions': [
            'Review high-memory processes and listening ports.',
            'Use Windows Event Viewer or PowerShell Get-EventLog for deeper diagnostics.',
          ],
        },
        'windowsStatus': status['windowsStatus'],
      };
    }

    final performanceResult = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.performanceCommand,
      timeout: const Duration(seconds: 12),
    );
    final portsResult = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.portsCommand,
      timeout: const Duration(seconds: 12),
    );
    final appsResult = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.applicationsCommand,
      timeout: const Duration(seconds: 12),
    );

    final performance = ServerStatusProbe.parsePerformanceOutput(
      performanceResult.stdout,
    );
    final ports = ServerStatusProbe.parsePorts(portsResult.stdout);
    final applications = ServerStatusProbe.parseApplications(appsResult.stdout);
    final diskMax = performance.diskUsage.isEmpty
        ? 0.0
        : performance.diskUsage
              .map((disk) => disk.usedPercent)
              .reduce((a, b) => a > b ? a : b);

    final risks = <String>[];
    final suggestions = <String>[];
    if (performance.counters.memoryPercent >= 90) {
      risks.add('High memory usage');
      suggestions.add('Inspect top memory processes and recent deploys.');
    }
    if (diskMax >= 85) {
      risks.add('High disk usage');
      suggestions.add('Check large logs, package caches, and old artifacts.');
    }
    if (ports.isEmpty) {
      risks.add('No listening ports returned');
      suggestions.add('Verify service state with systemctl or process list.');
    }
    if (applications.isNotEmpty && applications.first.cpuPercent >= 80) {
      risks.add('A process is consuming high CPU');
      suggestions.add('Inspect the top CPU process and related logs.');
    }

    final score =
        (100 -
                _opsPenalty(performance.counters.memoryPercent, 70, 95, 40) -
                _opsPenalty(diskMax, 75, 95, 35) -
                (ports.isEmpty ? 10 : 0))
            .clamp(0, 100)
            .round();
    final level = score < 45
        ? 'critical'
        : score < 75
        ? 'warning'
        : 'healthy';

    return {
      'connectionId': connectionId,
      'server': connection == null
          ? null
          : {
              'name': connection.name,
              'host': connection.host,
              'port': connection.port,
              'username': connection.username,
            },
      'health': {
        'score': score,
        'level': level,
        'risks': risks,
        'suggestions': suggestions,
      },
      'performance': {
        'memoryPercent': performance.counters.memoryPercent,
        'diskUsage': performance.diskUsage
            .map((item) => item.toJson())
            .toList(),
        'rawCounters': {
          'cpuTotal': performance.counters.cpuTotal,
          'cpuBusy': performance.counters.cpuBusy,
          'diskBytes': performance.counters.diskBytes,
          'networkBytes': performance.counters.networkBytes,
        },
      },
      'ports': ports.take(80).map((item) => item.toJson()).toList(),
      'applications': applications
          .take(40)
          .map((item) => item.toJson())
          .toList(),
      'stderr': {
        if (performanceResult.stderr.trim().isNotEmpty)
          'performance': _truncate(performanceResult.stderr),
        if (portsResult.stderr.trim().isNotEmpty)
          'ports': _truncate(portsResult.stderr),
        if (appsResult.stderr.trim().isNotEmpty)
          'applications': _truncate(appsResult.stderr),
      },
    };
  }

  Future<Map<String, dynamic>> _detectRemoteOs(String connectionId) async {
    final config = storageService.getConnection(connectionId);
    if (config != null) {
      return {
        'os': config.serverPlatform.name,
        'method': 'saved_server_platform',
        'details':
            'Configured as ${config.serverPlatform.displayName} in the server settings.',
      };
    }

    try {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: 'cmd /c ver',
        timeout: const Duration(seconds: 6),
      );
      final combined = '${result.stdout}\n${result.stderr}'.toLowerCase();
      if (result.exitCode == 0 && combined.contains('windows')) {
        return {
          'os': 'windows',
          'method': 'cmd /c ver',
          'details': _truncate(result.stdout.trim()),
        };
      }
    } catch (_) {}

    try {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: 'uname -a',
        timeout: const Duration(seconds: 6),
      );
      final output = result.stdout.trim();
      if (result.exitCode == 0 && output.isNotEmpty) {
        return {
          'os': 'linux',
          'method': 'uname -a',
          'details': _truncate(output),
        };
      }
    } catch (_) {}

    return {
      'os': 'unknown',
      'method': 'cmd /c ver, uname -a',
      'details':
          'Could not identify the remote OS. Ask the user or use generic read-only checks.',
    };
  }

  Future<Map<String, dynamic>> _windowsServerStatus(
    String connectionId,
    String? mode,
    Map<String, dynamic> os,
  ) async {
    final result = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.windowsStatusCommand,
      timeout: const Duration(seconds: 20),
    );

    if (_isWindowsPermissionProblem(result.stdout, result.stderr)) {
      return {
        'connectionId': connectionId,
        'os': os,
        'permissionError': true,
        'error': _windowsPermissionMessage,
        'stderr': _truncate(result.stderr),
      };
    }

    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      return {
        'connectionId': connectionId,
        'os': os,
        'error': result.stderr.trim().isEmpty
            ? 'Windows status command failed.'
            : _truncate(result.stderr),
      };
    }

    Object? parsed;
    try {
      parsed = jsonDecode(result.stdout);
    } catch (_) {
      parsed = {'raw': _truncate(result.stdout)};
    }

    return {
      'connectionId': connectionId,
      'os': os,
      'mode': mode?.isEmpty == true ? 'all' : mode ?? 'all',
      'windowsStatus': parsed,
      if (result.stderr.trim().isNotEmpty) 'stderr': _truncate(result.stderr),
    };
  }

  double _opsPenalty(
    double value,
    double warning,
    double critical,
    double maxPenalty,
  ) {
    if (value <= warning) return 0;
    if (value >= critical) return maxPenalty;
    return (value - warning) / (critical - warning) * maxPenalty;
  }

  bool _isWindowsPermissionProblem(String stdout, String stderr) {
    final combined = '$stdout\n$stderr'.toLowerCase();
    const needles = [
      'access is denied',
      'access denied',
      'administrator privileges',
      'administrator rights',
      'elevation is required',
      'requires elevation',
      'requested operation requires elevation',
      'run as administrator',
      'not have sufficient privilege',
      'not have the required privilege',
      'unauthorizedaccessexception',
      '拒绝访问',
      '权限不足',
      '需要提升',
      '管理员权限',
    ];
    return needles.any(combined.contains);
  }

  String get _windowsPermissionMessage =>
      'Windows permission denied: the current account does not have enough privileges for this operation. Use an Administrator/elevated account or grant the required permission, then try again.';

  String _truncate(String value) {
    if (value.length <= _maxToolTextChars) return value;
    return '${value.substring(0, _maxToolTextChars)}\n...[truncated]';
  }
}

const int _maxToolTextChars = 12000;
