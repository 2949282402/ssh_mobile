import 'dart:async';
import 'dart:convert';

import 'app_log_service.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

class AiToolService {
  final StorageService storageService;
  final SshService sshService;
  final SftpService sftpService;

  const AiToolService({
    required this.storageService,
    required this.sshService,
    required this.sftpService,
  });

  List<AiTool> get tools {
    return [
      AiTool(
        name: 'list_servers',
        description: 'List saved SSH servers. Does not reveal credentials.',
        properties: const {},
        handler: (_) async => _listServers(),
      ),
      AiTool(
        name: 'run_command',
        description:
            'Run a shell command on a selected server. Read-only diagnostics run immediately; write commands require explicit user approval in the app before execution.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'command': _string(
            'Shell command to run. Prefer read-only diagnostics unless the user asks for a write operation.',
          ),
        },
        required: const ['connectionId', 'command'],
        handler: (arguments) => _runCommand(arguments),
      ),
      AiTool(
        name: 'sftp_list_dir',
        description: 'List a remote directory through SFTP.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote directory path. Defaults to ".".'),
        },
        required: const ['connectionId'],
        handler: _listDir,
      ),
      AiTool(
        name: 'sftp_read_text',
        description:
            'Read a small remote text file through SFTP. Binary and large files are rejected.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
        },
        required: const ['connectionId', 'path'],
        handler: _readText,
      ),
    ];
  }

  List<Map<String, dynamic>> toolDefinitions() {
    return tools.map((tool) => tool.definition).toList();
  }

  AiToolApprovalRequest? approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) {
    if (name != 'run_command') return null;
    final connectionId = _arg(arguments, 'connectionId');
    final command = _arg(arguments, 'command');
    final review = reviewCommand(command);
    if (!review.requiresApproval) return null;
    final config = storageService.getConnection(connectionId);
    return AiToolApprovalRequest(
      toolName: name,
      connectionId: connectionId,
      connectionName: config?.name ?? connectionId,
      command: command,
      reason: review.reason,
    );
  }

  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    for (final tool in tools) {
      if (tool.name == name) {
        final startedAt = DateTime.now();
        AppLogService.instance.info(
          'AI tool started',
          details: 'tool=$name args=${_safeArguments(arguments)}',
        );
        try {
          final result = name == 'run_command'
              ? await _runCommand(arguments, approvedWrite: approvedWrite)
              : await tool.handler(arguments);
          AppLogService.instance.info(
            'AI tool completed',
            details:
                'tool=$name elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} resultChars=${result.length}',
          );
          return result;
        } catch (e, stackTrace) {
          AppLogService.instance.error(
            'AI tool failed',
            error: e,
            stackTrace: stackTrace,
            details: 'tool=$name args=${_safeArguments(arguments)}',
          );
          rethrow;
        }
      }
    }
    AppLogService.instance.warning('Unknown AI tool requested', details: name);
    return jsonEncode({'error': 'Unknown tool: $name'});
  }

  String _listServers() {
    final servers = storageService.connections
        .map(
          (item) => {
            'id': item.id,
            'name': item.name,
            'host': item.host,
            'port': item.port,
            'username': item.username,
            'launchMode': item.launchMode.name,
          },
        )
        .toList();
    return jsonEncode({'servers': servers});
  }

  Future<String> _runCommand(
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final command = _arg(arguments, 'command');
    final review = reviewCommand(command);
    if (review.blocked) {
      return jsonEncode({
        'error': review.reason,
        'command': command,
      });
    }
    if (review.requiresApproval && !approvedWrite) {
      return jsonEncode({
        'error': 'Write command requires user approval before execution.',
        'command': command,
      });
    }

    final timeoutSeconds = await storageService.getAiRequestTimeoutSeconds();
    late final RemoteCommandResult result;
    try {
      // This intentionally uses a one-shot SSH exec path, not the tmux-backed
      // terminal session path, so AI tools do not attach to user workspaces.
      // Some diagnostics, such as searching logs under /var or /, can be slow
      // on real servers, so AI tool commands get a longer timeout than UI
      // connection setup.
      result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: command,
        timeout: Duration(seconds: timeoutSeconds),
      );
    } on TimeoutException {
      AppLogService.instance.warning(
        'AI tool command timed out',
        details:
            'connectionId=$connectionId timeoutSeconds=$timeoutSeconds command=${_truncate(command)}',
      );
      return jsonEncode({
        'error':
            'Command timed out after $timeoutSeconds seconds. Narrow the search path or run a smaller diagnostic command.',
        'command': command,
      });
    }
    return jsonEncode({
      'exitCode': result.exitCode,
      'stdout': _truncate(result.stdout),
      'stderr': _truncate(result.stderr),
    });
  }

  Future<String> _listDir(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = (arguments['path'] as String?)?.trim();
    final entries = await sftpService.listDirectoryForConnection(
      connectionId,
      path?.isNotEmpty == true ? path! : '.',
    );
    return jsonEncode({
      'path': path?.isNotEmpty == true ? path : '.',
      'entries': entries
          .take(200)
          .map(
            (entry) => {
              'name': entry.name,
              'path': entry.path,
              'type': entry.isDirectory ? 'directory' : 'file',
              'size': entry.size,
              'modifiedAt': entry.modifiedAt?.toIso8601String(),
            },
          )
          .toList(),
      if (entries.length > 200) 'truncated': true,
    });
  }

  Future<String> _readText(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final text = await sftpService.readTextPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({
      'path': path,
      'content': _truncate(text),
      'truncated': text.length > _maxToolTextChars,
    });
  }

  String _arg(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.trim().isEmpty) {
      throw StateError('Missing tool argument: $key');
    }
    return value.trim();
  }

  AiCommandReview reviewCommand(String command) {
    final normalized = command.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const AiCommandReview.blocked('Command is empty');
    }

    final blocked = [
      'sudo -s',
      'sudo su',
      ' su ',
      'su -',
      'passwd',
      'sshpass',
      'password=',
      'private key',
    ];
    if (blocked.any(normalized.contains)) {
      return const AiCommandReview.blocked(
        'This command asks for elevated shells, passwords, or secret handling.',
      );
    }

    // Keep model-operated shell access intentionally narrow: diagnostics and
    // path discovery run directly; everything else pauses for user approval.
    final allowedPrefixes = [
      'cat ',
      'command -v ',
      'df ',
      'du ',
      'env',
      'free',
      'head ',
      'printenv',
      'readlink ',
      'realpath ',
      'journalctl ',
      'ls',
      'netstat ',
      'ps ',
      'pwd',
      'ss ',
      'stat ',
      'systemctl status ',
      'tail ',
      'top ',
      'uptime',
      'whereis ',
      'which ',
      'whoami',
    ];
    if (!allowedPrefixes.any(normalized.startsWith)) {
      return const AiCommandReview.requiresApproval(
        'This command may change server state.',
      );
    }
    return const AiCommandReview.readOnly();
  }

  String _truncate(String value) {
    if (value.length <= _maxToolTextChars) return value;
    return '${value.substring(0, _maxToolTextChars)}\n...[truncated]';
  }

  String _safeArguments(Map<String, dynamic> arguments) {
    return jsonEncode(
      arguments.map((key, value) {
        final lowerKey = key.toLowerCase();
        if (lowerKey.contains('key') ||
            lowerKey.contains('token') ||
            lowerKey.contains('secret') ||
            lowerKey.contains('password')) {
          return MapEntry(key, '[REDACTED]');
        }
        if (value is String && value.length > 300) {
          return MapEntry(key, '${value.substring(0, 300)}...[truncated]');
        }
        return MapEntry(key, value);
      }),
    );
  }

  static Map<String, dynamic> _string(String description) {
    return {'type': 'string', 'description': description};
  }
}

class AiToolApprovalRequest {
  final String toolName;
  final String connectionId;
  final String connectionName;
  final String command;
  final String reason;

  const AiToolApprovalRequest({
    required this.toolName,
    required this.connectionId,
    required this.connectionName,
    required this.command,
    required this.reason,
  });
}

class AiToolApprovalDecision {
  final bool approved;
  final bool abort;
  final String? feedback;

  const AiToolApprovalDecision.approved()
      : approved = true,
        abort = false,
        feedback = null;

  const AiToolApprovalDecision.rejected({
    this.abort = true,
    this.feedback,
  }) : approved = false;
}

class AiCommandReview {
  final bool requiresApproval;
  final bool blocked;
  final String reason;

  const AiCommandReview.readOnly()
      : requiresApproval = false,
        blocked = false,
        reason = 'Read-only diagnostic command.';

  const AiCommandReview.requiresApproval(this.reason)
      : requiresApproval = true,
        blocked = false;

  const AiCommandReview.blocked(this.reason)
      : requiresApproval = false,
        blocked = true;
}

class AiTool {
  final String name;
  final String description;
  final Map<String, dynamic> properties;
  final List<String> required;
  final Future<String> Function(Map<String, dynamic> arguments) handler;

  const AiTool({
    required this.name,
    required this.description,
    required this.properties,
    required this.handler,
    this.required = const [],
  });

  Map<String, dynamic> get definition {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
          'additionalProperties': false,
        },
      },
    };
  }
}

const int _maxToolTextChars = 12000;
