part of '../ai_tool_service.dart';

class ServerToolsProvider implements AiToolProvider {
  final ServerCatalogAdapter serverCatalogService;
  final ServerDiagnosticsAdapter serverDiagnosticsService;

  const ServerToolsProvider({
    required this.serverCatalogService,
    required this.serverDiagnosticsService,
  });

  @override
  Future<List<AiTool>> getTools(AiToolService service) async {
    return _getServerTools(service);
  }

  @override
  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    switch (name) {
      case 'list_servers':
        return jsonEncode({
          'servers': serverCatalogService.listServerSummaries(),
        });
      case 'get_server_details':
        return _getServerDetails(service, arguments);
      case 'update_server_metadata':
        return _updateServerMetadata(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'delete_server':
        return _deleteServer(service, arguments, approvedWrite: approvedWrite);
      case 'reorder_servers':
        return _reorderServers(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'detect_os':
        return _detectOsTool(service, arguments);
      case 'run_command':
        return _runCommand(service, arguments, approvedWrite: approvedWrite);
      case 'get_server_status':
        return _serverStatus(service, arguments);
      case 'generate_ops_report':
        return _opsReport(service, arguments);
      case 'inspect_service_health':
        return _inspectServiceHealth(service, arguments);
      case 'collect_incident_context':
        return _collectIncidentContext(service, arguments);
      case 'compare_server_states':
        return _compareServerStates(service, arguments);
      default:
        return null;
    }
  }

  Future<String> _getServerDetails(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final details = serverCatalogService.getServerDetails(
      service._arg(arguments, 'connectionId'),
    );
    if (details == null) {
      return jsonEncode({'error': 'Connection config not found.'});
    }
    return jsonEncode(details);
  }

  Future<String> _updateServerMetadata(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Server metadata changes require user approval.',
      });
    }
    final connectionId = service._arg(arguments, 'connectionId');
    final binding = service.activeApprovalExecutionBinding;
    final approvedUpdate = binding?.resourceSnapshot;
    if (binding?.resourceKind == 'server_metadata_update' &&
        approvedUpdate is! _ApprovedServerMetadataUpdate) {
      return jsonEncode({
        'error':
            'The approved server update is no longer available. Review it and approve again.',
        'code': 'approval_target_changed',
      });
    }
    final changes = <String, dynamic>{
      for (final entry in arguments.entries)
        if (entry.key != 'connectionId' && entry.value != null)
          entry.key: entry.value,
    };
    if (changes.isEmpty && approvedUpdate is! _ApprovedServerMetadataUpdate) {
      return jsonEncode({
        'updated': false,
        'error': 'No metadata fields were provided to update.',
      });
    }
    return jsonEncode(
      await serverCatalogService.updateServerMetadata(
        connectionId: connectionId,
        changes: approvedUpdate is _ApprovedServerMetadataUpdate
            ? const <String, dynamic>{}
            : changes,
        approvedTarget: approvedUpdate is _ApprovedServerMetadataUpdate
            ? binding!.connectionTargets[connectionId]
            : null,
        approvedCurrent: approvedUpdate is _ApprovedServerMetadataUpdate
            ? ConnectionConfig.fromJson(approvedUpdate.expected.toJson())
            : null,
        approvedCandidate: approvedUpdate is _ApprovedServerMetadataUpdate
            ? ConnectionConfig.fromJson(approvedUpdate.candidate.toJson())
            : null,
      ),
    );
  }

  Future<String> _deleteServer(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting a saved server requires user approval.',
      });
    }
    return jsonEncode(
      await serverCatalogService.deleteServer(
        service._arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _reorderServers(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Reordering saved servers requires user approval.',
      });
    }
    return jsonEncode(
      await serverCatalogService.reorderServers(
        service._stringList(arguments['orderedIds']),
      ),
    );
  }

  Future<String> _detectOsTool(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(
      await serverDiagnosticsService.detectOs(
        service._arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _serverStatus(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final mode = service._optionalString(arguments, 'mode')?.toLowerCase();
    return jsonEncode(
      await serverDiagnosticsService.getStatus(
        connectionId: connectionId,
        mode: mode,
      ),
    );
  }

  Future<String> _opsReport(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(
      await serverDiagnosticsService.generateOpsReport(
        service._arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _runCommand(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final command = service._arg(arguments, 'command');
    final config = service.storageService.getConnection(connectionId);
    if (config == null) {
      return jsonEncode({
        'error': 'Connection config not found.',
        'connectionId': connectionId,
      });
    }
    final review = service.reviewCommand(
      command,
      platform: config.serverPlatform,
    );
    if (review.blocked) {
      return jsonEncode({
        'error': review.reason,
        'serverPlatform': config.serverPlatform.name,
        'command': service.secretPolicy.previewText(command, maxChars: 240),
      });
    }
    if (review.requiresApproval && !approvedWrite) {
      return jsonEncode({
        'error': 'Write command requires user approval before execution.',
        'serverPlatform': config.serverPlatform.name,
        'command': service.secretPolicy.previewText(command, maxChars: 240),
      });
    }
    final timeoutSeconds = await service.storageService
        .getAiRequestTimeoutSeconds();
    late final RemoteCommandResult result;
    try {
      result = await service.sshService.runOneShotCommand(
        connectionId: connectionId,
        command: command,
        timeout: Duration(seconds: timeoutSeconds),
      );
    } on TimeoutException {
      return jsonEncode({
        'error':
            'Command timed out after $timeoutSeconds seconds. Narrow the command or search path and try again.',
        'serverPlatform': config.serverPlatform.name,
      });
    }
    if (config.serverPlatform == ServerPlatform.windows &&
        _hasWindowsPermissionProblem(result.stdout, result.stderr)) {
      return jsonEncode({
        'exitCode': result.exitCode,
        'serverPlatform': config.serverPlatform.name,
        'permissionError': true,
        'error': _windowsPermissionMessage,
        'stdout': service._truncate(result.stdout),
        'stderr': service._truncate(result.stderr),
      });
    }
    return jsonEncode({
      'exitCode': result.exitCode,
      'serverPlatform': config.serverPlatform.name,
      'stdout': service._truncate(result.stdout),
      'stderr': service._truncate(result.stderr),
    });
  }

  bool _hasWindowsPermissionProblem(String stdout, String stderr) {
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
      'Windows permission denied: the current account does not have enough privileges for this operation. Use an Administrator or elevated account, or grant the required permission and try again.';

  Future<String> _inspectServiceHealth(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final serviceName = service._arg(arguments, 'serviceName');
    final os = await serverDiagnosticsService.detectOs(connectionId);
    final command = os['os'] == 'windows'
        ? 'powershell -NoProfile -Command "Get-Service -Name \'$serviceName\' | Select-Object Name, Status, StartType | ConvertTo-Json -Compress"'
        : 'systemctl status --no-pager --full $serviceName';
    final result = await service.sshService.runOneShotCommand(
      connectionId: connectionId,
      command: command,
      timeout: const Duration(seconds: 12),
    );
    final report = await serverDiagnosticsService.generateOpsReport(
      connectionId,
    );
    return jsonEncode({
      'connectionId': connectionId,
      'serviceName': serviceName,
      'os': os,
      'serviceStatus': {
        'exitCode': result.exitCode,
        'stdout': service._truncate(result.stdout),
        'stderr': service._truncate(result.stderr),
      },
      'opsReport': report,
    });
  }

  Future<String> _collectIncidentContext(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final focus = service._optionalString(arguments, 'focus');
    final path = service._optionalString(arguments, 'path');
    final report = await serverDiagnosticsService.generateOpsReport(
      connectionId,
    );
    final health = service.performanceMonitorToolService.getHealth(
      connectionIds: [connectionId],
    );
    final alerts = service.performanceMonitorToolService.getAlerts(limit: 10);
    Map<String, dynamic>? fileContext;
    if (path != null && path.trim().isNotEmpty) {
      final blocked = service._secretPathBlocked(path);
      if (blocked == null) {
        final info = await service.sftpService.statPathForConnection(
          connectionId: connectionId,
          path: path,
        );
        fileContext = info.toJson();
      }
    }
    return jsonEncode({
      'connectionId': connectionId,
      if (focus?.trim().isNotEmpty == true) 'focus': focus,
      'opsReport': report,
      'monitorHealth': health,
      'monitorAlerts': alerts,
      'pathContext': ?fileContext,
    });
  }

  Future<String> _compareServerStates(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final connectionIds = service._stringList(arguments['connectionIds']);
    final mode = service._optionalString(arguments, 'mode');
    final reports = await Future.wait(
      connectionIds.map(
        (connectionId) => serverDiagnosticsService.getStatus(
          connectionId: connectionId,
          mode: mode,
        ),
      ),
    );
    return jsonEncode({
      'mode': mode ?? 'all',
      'servers': reports,
      'connectionIds': connectionIds,
      'compared': reports.length,
    });
  }

  List<AiTool> _getServerTools(AiToolService service) {
    return [
      AiTool(
        name: 'list_servers',
        description: 'List saved SSH servers. Does not reveal credentials.',
        properties: const {},
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.diagnostics,
        },
        handler: (_) async =>
            jsonEncode({'servers': serverCatalogService.listServerSummaries()}),
      ),
      AiTool(
        name: 'get_server_details',
        description:
            'Get saved non-sensitive metadata for one SSH server, including session overview. Does not reveal credentials.',
        properties: {'connectionId': _string('Server connection id.')},
        required: const ['connectionId'],
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.diagnostics,
        },
        handler: (args) => _getServerDetails(service, args),
      ),
      AiTool(
        name: 'update_server_metadata',
        description:
            'Update non-sensitive server metadata such as name, host, port, username, group, launch mode, platform, keep-alive settings, terminal size, or jump-host metadata. Passwords, private keys, and API keys are never readable or writable. This change requires user approval.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'name': _string('Optional server display name.'),
          'host': _string('Optional server hostname or IP address.'),
          'port': _int('Optional SSH port.'),
          'username': _string('Optional SSH username.'),
          'group': _string('Optional server group name.'),
          'serverPlatform': {
            'type': 'string',
            'enum': ServerPlatform.values.map((item) => item.name).toList(),
            'description': 'Optional saved server platform.',
          },
          'launchMode': {
            'type': 'string',
            'enum': TerminalLaunchMode.values.map((item) => item.name).toList(),
            'description': 'Optional terminal launch mode.',
          },
          'tmuxAutoDeleteSeconds': _int(
            'Optional tmux auto-delete idle timeout in seconds.',
          ),
          'keepAlive': _bool('Optional keep-alive enabled flag.'),
          'keepAliveInterval': _int('Optional keep-alive interval in seconds.'),
          'terminalWidth': _int('Optional default terminal width.'),
          'terminalHeight': _int('Optional default terminal height.'),
          'jumpHost': _string('Optional jump host hostname.'),
          'jumpPort': _int('Optional jump host port.'),
          'jumpUsername': _string('Optional jump host username.'),
        },
        required: const ['connectionId'],
        executionMode: AiToolExecutionMode.stateChanging,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.settings,
        },
        handler: (arguments) =>
            _updateServerMetadata(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'delete_server',
        description:
            'Delete one saved SSH server from the client app. Credentials stored for that server are also removed locally. This is destructive and requires user approval.',
        properties: {'connectionId': _string('Server connection id.')},
        required: const ['connectionId'],
        executionMode: AiToolExecutionMode.stateChanging,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.settings,
        },
        handler: (arguments) =>
            _deleteServer(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'reorder_servers',
        description:
            'Reorder the saved SSH servers by providing the full ordered server id list. This changes local app state and requires user approval.',
        properties: {
          'orderedIds': _stringArray(
            'Every saved server id exactly once, in the desired order.',
            minimumItems: 1,
          ),
        },
        required: const ['orderedIds'],
        executionMode: AiToolExecutionMode.stateChanging,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.settings,
        },
        handler: (arguments) =>
            _reorderServers(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'detect_os',
        description:
            'Detect whether a selected SSH server is Windows or Linux or Unix before choosing OS-specific commands.',
        properties: {'connectionId': _string('Server connection id.')},
        required: const ['connectionId'],
        requiresServerSelection: true,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.diagnostics,
        },
        handler: (args) => _detectOsTool(service, args),
      ),
      AiTool(
        name: 'run_command',
        description:
            'Run a shell command on a selected server. The saved server platform is enforced: use Linux or POSIX commands only on Linux servers, and explicit cmd /c or PowerShell diagnostics only on Windows servers. Delete commands, environment dumps, and commands that reference secret-bearing paths are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'command': _string(
            'Shell command to run. On Windows use explicit cmd /c or powershell or pwsh read-only diagnostics. On Linux use POSIX or Linux commands such as uname, ps, ss, df, cat.',
          ),
        },
        required: const ['connectionId', 'command'],
        requiresServerSelection: true,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.diagnostics,
        },
        cacheTtl: const Duration(seconds: 10),
        handler: (arguments) =>
            _runCommand(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'get_server_status',
        description:
            'Get read-only server status for diagnostics. Modes: performance, ports, applications, or all.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'mode': _string(
            'Status mode: performance, ports, applications, or all. Defaults to all.',
          ),
        },
        required: const ['connectionId'],
        requiresServerSelection: true,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.monitor,
          AiToolCapability.diagnostics,
        },
        cacheTtl: const Duration(seconds: 15),
        handler: (args) => _serverStatus(service, args),
      ),
      AiTool(
        name: 'generate_ops_report',
        description:
            'Collect read-only server status and return an operations report payload with health score, risks, ports, applications, and suggested next checks.',
        properties: {'connectionId': _string('Server connection id.')},
        required: const ['connectionId'],
        requiresServerSelection: true,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.monitor,
          AiToolCapability.diagnostics,
        },
        cacheTtl: const Duration(seconds: 20),
        handler: (args) => _opsReport(service, args),
      ),
      AiTool(
        name: 'inspect_service_health',
        description:
            'Collect a structured service-health snapshot for one server and one service name, combining read-only service status with the current ops report.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'serviceName': _string(
            'Service name such as nginx, sshd, docker, or mysql.',
          ),
        },
        required: const ['connectionId', 'serviceName'],
        requiresServerSelection: true,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.monitor,
          AiToolCapability.diagnostics,
        },
        cacheTtl: const Duration(seconds: 15),
        handler: (args) => _inspectServiceHealth(service, args),
      ),
      AiTool(
        name: 'collect_incident_context',
        description:
            'Collect a structured incident context bundle for one server, including ops report, monitor health, alerts, and optional remote path metadata.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'focus': _string(
            'Optional incident focus such as nginx, disk, memory, ports, or login failures.',
          ),
          'path': _string(
            'Optional remote file path to inspect metadata only.',
          ),
        },
        required: const ['connectionId'],
        requiresServerSelection: true,
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.monitor,
          AiToolCapability.sftp,
          AiToolCapability.diagnostics,
        },
        cacheTtl: const Duration(seconds: 15),
        handler: (args) => _collectIncidentContext(service, args),
      ),
      AiTool(
        name: 'compare_server_states',
        description:
            'Compare the structured status of two or more servers in one read-only call. Useful for drift checks and incident diffs.',
        properties: {
          'connectionIds': _stringArray(
            'Two or more server connection ids to compare.',
            minimumItems: 2,
          ),
          'mode': _string(
            'Optional status mode: performance, ports, applications, or all.',
          ),
        },
        required: const ['connectionIds'],
        capabilities: const {
          AiToolCapability.server,
          AiToolCapability.monitor,
          AiToolCapability.diagnostics,
        },
        cacheTtl: const Duration(seconds: 15),
        handler: (args) => _compareServerStates(service, args),
      ),
    ];
  }
}
