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
        return jsonEncode(
            {'servers': serverCatalogService.listServerSummaries()});
      case 'get_server_details':
        return _getServerDetails(service, arguments);
      case 'update_server_metadata':
        return _updateServerMetadata(service, arguments,
            approvedWrite: approvedWrite);
      case 'delete_server':
        return _deleteServer(service, arguments, approvedWrite: approvedWrite);
      case 'reorder_servers':
        return _reorderServers(service, arguments,
            approvedWrite: approvedWrite);
      case 'detect_os':
        return _detectOsTool(service, arguments);
      case 'run_command':
        return _runCommand(service, arguments, approvedWrite: approvedWrite);
      case 'get_server_status':
        return _serverStatus(service, arguments);
      case 'generate_ops_report':
        return _opsReport(service, arguments);
      default:
        return null;
    }
  }

  Future<String> _getServerDetails(
      AiToolService service, Map<String, dynamic> arguments) async {
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
    final changes = Map<String, dynamic>.from(arguments)
      ..remove('connectionId');
    if (changes.isEmpty) {
      return jsonEncode({
        'updated': false,
        'error': 'No metadata fields were provided to update.',
      });
    }
    return jsonEncode(
      await serverCatalogService.updateServerMetadata(
        connectionId: connectionId,
        changes: changes,
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
      await serverCatalogService
          .deleteServer(service._arg(arguments, 'connectionId')),
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
      AiToolService service, Map<String, dynamic> arguments) async {
    return jsonEncode(
      await serverDiagnosticsService
          .detectOs(service._arg(arguments, 'connectionId')),
    );
  }

  Future<String> _serverStatus(
      AiToolService service, Map<String, dynamic> arguments) async {
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
      AiToolService service, Map<String, dynamic> arguments) async {
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
    final review =
        service.reviewCommand(command, platform: config.serverPlatform);
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
    final timeoutSeconds =
        await service.storageService.getAiRequestTimeoutSeconds();
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

  List<AiTool> _getServerTools(AiToolService service) {
    return [
      AiTool(
        name: 'list_servers',
        description: 'List saved SSH servers. Does not reveal credentials.',
        properties: const {},
        handler: (_) async =>
            jsonEncode({'servers': serverCatalogService.listServerSummaries()}),
      ),
      AiTool(
        name: 'get_server_details',
        description:
            'Get saved non-sensitive metadata for one SSH server, including session overview. Does not reveal credentials.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
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
          'keepAliveInterval': _int(
            'Optional keep-alive interval in seconds.',
          ),
          'terminalWidth': _int('Optional default terminal width.'),
          'terminalHeight': _int('Optional default terminal height.'),
          'jumpHost': _string('Optional jump host hostname.'),
          'jumpPort': _int('Optional jump host port.'),
          'jumpUsername': _string('Optional jump host username.'),
        },
        required: const ['connectionId'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) => _updateServerMetadata(
          service,
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'delete_server',
        description:
            'Delete one saved SSH server from the client app. Credentials stored for that server are also removed locally. This is destructive and requires user approval.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        executionMode: AiToolExecutionMode.stateChanging,
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
        handler: (arguments) => _reorderServers(
          service,
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'detect_os',
        description:
            'Detect whether a selected SSH server is Windows or Linux or Unix before choosing OS-specific commands.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
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
        handler: (args) => _serverStatus(service, args),
      ),
      AiTool(
        name: 'generate_ops_report',
        description:
            'Collect read-only server status and return an operations report payload with health score, risks, ports, applications, and suggested next checks.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: (args) => _opsReport(service, args),
      ),
    ];
  }
}
