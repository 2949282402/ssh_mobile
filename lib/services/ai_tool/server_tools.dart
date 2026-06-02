part of '../ai_tool_service.dart';

extension _ServerTools on AiToolService {
  Future<String> _getServerDetails(Map<String, dynamic> arguments) async {
    final details = serverCatalogService.getServerDetails(
      _arg(arguments, 'connectionId'),
    );
    if (details == null) {
      return jsonEncode({'error': 'Connection config not found.'});
    }
    return jsonEncode(details);
  }

  Future<String> _updateServerMetadata(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Server metadata changes require user approval.',
      });
    }
    final connectionId = _arg(arguments, 'connectionId');
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
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting a saved server requires user approval.',
      });
    }
    return jsonEncode(
      await serverCatalogService.deleteServer(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _reorderServers(
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
        _stringList(arguments['orderedIds']),
      ),
    );
  }

  Future<String> _detectOsTool(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await serverDiagnosticsService.detectOs(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _serverStatus(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final mode = _optionalString(arguments, 'mode')?.toLowerCase();
    return jsonEncode(
      await serverDiagnosticsService.getStatus(
        connectionId: connectionId,
        mode: mode,
      ),
    );
  }

  Future<String> _opsReport(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await serverDiagnosticsService.generateOpsReport(
        _arg(arguments, 'connectionId'),
      ),
    );
  }

  List<AiTool> _getServerTools() {
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
        handler: _getServerDetails,
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
        handler: (arguments) => _updateServerMetadata(
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
        handler: (arguments) => _deleteServer(arguments, approvedWrite: false),
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
        handler: (arguments) => _reorderServers(
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
        handler: _detectOsTool,
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
        handler: (arguments) => _runCommand(arguments, approvedWrite: false),
      ),
    ];
  }
}
