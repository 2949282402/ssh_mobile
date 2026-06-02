part of '../ai_tool_service.dart';

extension _SshTools on AiToolService {
  Future<String> _sshListSessions(Map<String, dynamic> arguments) async {
    final filterConnectionId = _optionalString(arguments, 'connectionId');
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

  Future<String> _sshOpenSession(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final sessionId = await sshService.openSession(
      connectionId,
      displayName: _optionalString(arguments, 'displayName'),
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
      Map<String, dynamic> arguments) async {
    final sessionId = _arg(arguments, 'sessionId');
    final connectionId = _arg(arguments, 'connectionId');
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

  Future<String> _sshRenameSession(Map<String, dynamic> arguments) async {
    final sessionId = _arg(arguments, 'sessionId');
    final renamed =
        sshService.renameSession(sessionId, _arg(arguments, 'name'));
    final session = sshService.getSession(sessionId);
    return jsonEncode({
      'renamed': renamed,
      'session': session == null ? null : _sshSessionToJson(session),
    });
  }

  Future<String> _sshCloseSession(Map<String, dynamic> arguments) async {
    final sessionId = _arg(arguments, 'sessionId');
    await sshService.disconnectSession(sessionId);
    return jsonEncode({
      'closed': true,
      'sessionId': sessionId,
    });
  }

  Future<String> _sshCloseServerSessions(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    await sshService.disconnectSessionsForConnection(connectionId);
    return jsonEncode({
      'closed': true,
      'connectionId': connectionId,
    });
  }

  Future<String> _sshRestoreTmuxSessions(Map<String, dynamic> arguments) async {
    await sshService.restoreTmuxSessions();
    return jsonEncode({
      'restored': true,
      'sessions': sshService.sessions.map(_sshSessionToJson).toList(),
    });
  }

  Future<String> _sshListTerminalHistory(Map<String, dynamic> arguments) async {
    final connectionId = _optionalString(arguments, 'connectionId');
    final limit = _optionalInt(arguments, 'limit') ?? 50;
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
    Map<String, dynamic> arguments,
  ) async {
    final sessionId = _arg(arguments, 'sessionId');
    await sshService.removeTerminalHistoryRecord(sessionId);
    return jsonEncode({
      'deleted': true,
      'sessionId': sessionId,
    });
  }

  Future<String> _runCommand(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final command = _arg(arguments, 'command');
    final config = storageService.getConnection(connectionId);
    if (config == null) {
      return jsonEncode({
        'error': 'Connection config not found.',
        'connectionId': connectionId,
      });
    }
    final review = reviewCommand(command, platform: config.serverPlatform);
    if (review.blocked) {
      return jsonEncode({
        'error': review.reason,
        'serverPlatform': config.serverPlatform.name,
        'command': secretPolicy.previewText(command, maxChars: 240),
      });
    }
    if (review.requiresApproval && !approvedWrite) {
      return jsonEncode({
        'error': 'Write command requires user approval before execution.',
        'serverPlatform': config.serverPlatform.name,
        'command': secretPolicy.previewText(command, maxChars: 240),
      });
    }
    final timeoutSeconds = await storageService.getAiRequestTimeoutSeconds();
    late final RemoteCommandResult result;
    try {
      result = await sshService.runOneShotCommand(
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
        'stdout': _truncate(result.stdout),
        'stderr': _truncate(result.stderr),
      });
    }
    return jsonEncode({
      'exitCode': result.exitCode,
      'serverPlatform': config.serverPlatform.name,
      'stdout': _truncate(result.stdout),
      'stderr': _truncate(result.stderr),
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

  List<AiTool> _getSshTools() {
    return [
      AiTool(
        name: 'ssh_list_sessions',
        description:
            'List current SSH terminal sessions and their metadata without exposing raw terminal output.',
        properties: {
          'connectionId': _string('Optional server connection id filter.'),
        },
        handler: _sshListSessions,
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
        handler: _sshOpenSession,
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
        handler: _sshEnsureSessionConnected,
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
        handler: _sshRenameSession,
      ),
      AiTool(
        name: 'ssh_close_session',
        description:
            'Close one SSH terminal session. Returns session metadata only.',
        properties: {
          'sessionId': _string('Existing session id.'),
        },
        required: const ['sessionId'],
        handler: _sshCloseSession,
      ),
      AiTool(
        name: 'ssh_close_server_sessions',
        description:
            'Close all SSH terminal sessions for one server connection id.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _sshCloseServerSessions,
      ),
      AiTool(
        name: 'ssh_restore_tmux_sessions',
        description:
            'Restore saved tmux-backed SSH sessions after an app restart. Returns summary metadata only.',
        properties: const {},
        handler: _sshRestoreTmuxSessions,
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
        handler: _sshListTerminalHistory,
      ),
      AiTool(
        name: 'ssh_delete_terminal_history_record',
        description:
            'Delete one saved terminal history record by session id. Does not access raw terminal output.',
        properties: {
          'sessionId': _string('Terminal history session id.'),
        },
        required: const ['sessionId'],
        handler: _sshDeleteTerminalHistoryRecord,
      ),
    ];
  }
}
