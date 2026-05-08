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
            'Run a safe read-only shell command on a selected server. Destructive commands are rejected.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'command': _string('Read-only shell command to run.'),
        },
        required: const ['connectionId', 'command'],
        handler: _runCommand,
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

  Future<String> execute(String name, Map<String, dynamic> arguments) async {
    for (final tool in tools) {
      if (tool.name == name) {
        final startedAt = DateTime.now();
        AppLogService.instance.info(
          'AI tool started',
          details: 'tool=$name args=${_safeArguments(arguments)}',
        );
        try {
          final result = await tool.handler(arguments);
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

  Future<String> _runCommand(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final command = _arg(arguments, 'command');
    final rejectedReason = _rejectedCommandReason(command);
    if (rejectedReason != null) {
      return jsonEncode({
        'error': rejectedReason,
        'command': command,
      });
    }

    final result = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: command,
    );
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

  String? _rejectedCommandReason(String command) {
    final normalized = command.trim().toLowerCase();
    if (normalized.isEmpty) return 'Command is empty';
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
      return 'Only read-only diagnostic commands are allowed in this version.';
    }
    final blocked = [
      ' rm ',
      'rm ',
      'sudo ',
      ' chmod ',
      ' chown ',
      ' mv ',
      ' cp ',
      ' >',
      '>>',
      '| sh',
      '| bash',
      '&&',
      ';',
      '`',
      r'$(',
    ];
    if (blocked.any(normalized.contains)) {
      return 'This command contains a blocked destructive or compound operator.';
    }
    return null;
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
