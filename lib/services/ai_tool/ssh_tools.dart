part of '../ai_tool_service.dart';

class SshToolsProvider implements AiToolProvider {
  final SshClientAdapter sshService;
  final StorageService storageService;
  final ToolSecretPolicy secretPolicy;

  const SshToolsProvider({
    required this.sshService,
    required this.storageService,
    required this.secretPolicy,
  });

  @override
  Future<List<AiTool>> getTools(AiToolService service) async {
    return [
      AiTool(
        name: 'ssh_list_sessions',
        description:
            'List current SSH terminal sessions and their metadata without exposing raw terminal output.',
        properties: {
          'connectionId': _string('Optional server connection id filter.'),
        },
        handler: (args) => _sshListSessions(service, args),
      ),
      AiTool(
        name: 'ssh_open_session',
        description:
            'Open a new SSH terminal session using the saved server credentials. Returns session metadata only.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'displayName': _string('Optional display name for the new session.'),
        },
        required: const ['connectionId'],
        handler: (arguments) =>
            _sshOpenSession(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'ssh_ensure_session_connected',
        description:
            'Ensure an existing SSH terminal session is connected. Returns session metadata only.',
        properties: {
          'sessionId': _string('Existing session id.'),
          'connectionId': _string('Server connection id for that session.'),
        },
        required: const ['sessionId', 'connectionId'],
        handler: (args) => _sshEnsureSessionConnected(service, args),
      ),
      AiTool(
        name: 'ssh_rename_session',
        description:
            'Rename an SSH terminal session display name. Returns session metadata only.',
        properties: {
          'sessionId': _string('Existing session id.'),
          'name': _string('New display name.'),
        },
        required: const ['sessionId', 'name'],
        handler: (args) => _sshRenameSession(service, args),
      ),
      AiTool(
        name: 'ssh_close_session',
        description:
            'Close one SSH terminal session. Returns session metadata only.',
        properties: {
          'sessionId': _string('Existing session id.'),
        },
        required: const ['sessionId'],
        handler: (arguments) =>
            _sshCloseSession(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'ssh_close_server_sessions',
        description:
            'Close all SSH terminal sessions for one server connection id.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: (arguments) =>
            _sshCloseServerSessions(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'ssh_restore_tmux_sessions',
        description:
            'Restore saved tmux-backed SSH sessions after an app restart. Returns summary metadata only.',
        properties: const {},
        handler: (arguments) =>
            _sshRestoreTmuxSessions(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'ssh_list_terminal_history',
        description:
            'List saved terminal history records by metadata only. Does not expose raw terminal output.',
        properties: {
          'connectionId': _string('Optional server connection id filter.'),
          'limit': _int(
            'Maximum number of records to return. Defaults to 50.',
            minimum: 1,
            maximum: 200,
            defaultValue: 50,
          ),
        },
        handler: (args) => _sshListTerminalHistory(service, args),
      ),
      AiTool(
        name: 'ssh_delete_terminal_history_record',
        description:
            'Delete one saved terminal history record by session id. Does not access raw terminal output.',
        properties: {
          'sessionId': _string('Terminal history session id.'),
        },
        required: const ['sessionId'],
        handler: (arguments) => _sshDeleteTerminalHistoryRecord(
            service, arguments,
            approvedWrite: false),
      ),
    ];
  }

  @override
  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    switch (name) {
      case 'ssh_list_sessions':
        return _sshListSessions(service, arguments);
      case 'ssh_open_session':
        return _sshOpenSession(service, arguments,
            approvedWrite: approvedWrite);
      case 'ssh_ensure_session_connected':
        return _sshEnsureSessionConnected(service, arguments);
      case 'ssh_rename_session':
        return _sshRenameSession(service, arguments);
      case 'ssh_close_session':
        return _sshCloseSession(service, arguments,
            approvedWrite: approvedWrite);
      case 'ssh_close_server_sessions':
        return _sshCloseServerSessions(service, arguments,
            approvedWrite: approvedWrite);
      case 'ssh_restore_tmux_sessions':
        return _sshRestoreTmuxSessions(service, arguments,
            approvedWrite: approvedWrite);
      case 'ssh_list_terminal_history':
        return _sshListTerminalHistory(service, arguments);
      case 'ssh_delete_terminal_history_record':
        return _sshDeleteTerminalHistoryRecord(service, arguments,
            approvedWrite: approvedWrite);
      default:
        return null;
    }
  }

  Future<String> _sshListSessions(
      AiToolService service, Map<String, dynamic> arguments) async {
    final filterConnectionId =
        service._optionalString(arguments, 'connectionId');
    final sessions = sshService.sessions
        .where((session) {
          return filterConnectionId == null ||
              session.connectionId == filterConnectionId;
        })
        .map(_sshSessionToJson)
        .toList(growable: false);
    return jsonEncode({
      'sessions': sessions,
      'serverOverview': {
        'windowCount': sshService.serverOverviewSnapshot.windowCount,
        'byConnection': {
          for (final entry
              in sshService.serverOverviewSnapshot.byConnection.entries)
            entry.key: {
              'count': entry.value.count,
              'latestState': entry.value.latestState?.name,
              'hasConnected': entry.value.hasConnected,
            },
        },
      },
    });
  }

  Future<String> _sshOpenSession(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Opening an SSH session requires user approval.',
        'connectionId': connectionId,
      });
    }
    final sessionId = await sshService.openSession(
      connectionId,
      displayName: service._optionalString(arguments, 'displayName'),
    );
    final session = sessionId == null ? null : sshService.getSession(sessionId);
    return jsonEncode({
      'opened': sessionId != null,
      'connectionId': connectionId,
      'session': session == null ? null : _sshSessionToJson(session),
      if (sessionId == null)
        'error': sshService.errorMessage ?? 'Unable to open session.',
    });
  }

  Future<String> _sshEnsureSessionConnected(
      AiToolService service, Map<String, dynamic> arguments) async {
    final sessionId = service._arg(arguments, 'sessionId');
    final connectionId = service._arg(arguments, 'connectionId');
    final connected = await sshService.ensureSessionConnected(
      sessionId,
      connectionId,
    );
    final session = sshService.getSession(sessionId);
    return jsonEncode({
      'connected': connected,
      'session': session == null ? null : _sshSessionToJson(session),
    });
  }

  Future<String> _sshRenameSession(
      AiToolService service, Map<String, dynamic> arguments) async {
    final sessionId = service._arg(arguments, 'sessionId');
    final renamed =
        sshService.renameSession(sessionId, service._arg(arguments, 'name'));
    final session = sshService.getSession(sessionId);
    return jsonEncode({
      'renamed': renamed,
      'session': session == null ? null : _sshSessionToJson(session),
    });
  }

  Future<String> _sshCloseSession(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final sessionId = service._arg(arguments, 'sessionId');
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Closing an SSH session requires user approval.',
        'sessionId': sessionId,
      });
    }
    await sshService.disconnectSession(sessionId);
    return jsonEncode({
      'closed': true,
      'sessionId': sessionId,
    });
  }

  Future<String> _sshCloseServerSessions(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    if (!approvedWrite) {
      return jsonEncode({
        'error':
            'Closing all SSH sessions for a server requires user approval.',
        'connectionId': connectionId,
      });
    }
    await sshService.disconnectSessionsForConnection(connectionId);
    return jsonEncode({
      'closed': true,
      'connectionId': connectionId,
    });
  }

  Future<String> _sshRestoreTmuxSessions(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error':
            'Restoring saved tmux-backed SSH sessions requires user approval.',
      });
    }
    await sshService.restoreTmuxSessions();
    return jsonEncode({
      'restored': true,
      'sessions': sshService.sessions.map(_sshSessionToJson).toList(),
    });
  }

  Future<String> _sshListTerminalHistory(
      AiToolService service, Map<String, dynamic> arguments) async {
    final connectionId = service._optionalString(arguments, 'connectionId');
    final limit = service._optionalInt(arguments, 'limit') ?? 50;
    var records = await sshService.loadTerminalHistoryRecords();
    if (connectionId != null) {
      records = records
          .where((record) => record.connectionId == connectionId)
          .toList(growable: false);
    }
    final visible = records.take(limit).map(_terminalHistoryToJson).toList();
    return jsonEncode({
      'records': visible,
      'returned': visible.length,
      'limit': limit,
      'truncated': records.length > visible.length,
    });
  }

  Future<String> _sshDeleteTerminalHistoryRecord(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final sessionId = service._arg(arguments, 'sessionId');
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting saved terminal history requires user approval.',
        'sessionId': sessionId,
      });
    }
    await sshService.removeTerminalHistoryRecord(sessionId);
    return jsonEncode({
      'deleted': true,
      'sessionId': sessionId,
    });
  }

  Map<String, dynamic> _sshSessionToJson(SshSession session) {
    return {
      'id': session.id,
      'connectionId': session.connectionId,
      'connectionName': session.connectionName,
      'displayName': session.displayName,
      'tmuxSessionName': session.tmuxSessionName,
      'tmuxKillCommand': session.tmuxKillCommand,
      'tmuxAutoDeleteSeconds': session.tmuxAutoDeleteSeconds,
      'state': session.state.name,
      'isConnected': session.isConnected,
      'errorMessage': session.errorMessage,
      'createdAt': session.createdAt.toIso8601String(),
      'updatedAt': session.updatedAt.toIso8601String(),
      'estimatedMemoryBytes': session.estimatedMemoryBytes,
    };
  }

  Map<String, dynamic> _terminalHistoryToJson(TerminalHistoryRecord record) {
    return {
      'sessionId': record.sessionId,
      'connectionId': record.connectionId,
      'connectionName': record.connectionName,
      'displayName': record.displayName,
      'tmuxSessionName': record.tmuxSessionName,
      'tmuxKillCommand': record.tmuxKillCommand,
      'state': record.state,
      'errorMessage': record.errorMessage,
      'createdAt': record.createdAt.toIso8601String(),
      'updatedAt': record.updatedAt.toIso8601String(),
    };
  }
}
