import 'dart:convert';

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

  List<Map<String, dynamic>> toolDefinitions() {
    return [
      _tool(
        name: 'list_servers',
        description: 'List saved SSH servers. Does not reveal credentials.',
        properties: const {},
      ),
      _tool(
        name: 'run_command',
        description:
            'Run a safe read-only shell command on a selected server. Destructive commands are rejected.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'command': _string('Read-only shell command to run.'),
        },
        required: const ['connectionId', 'command'],
      ),
      _tool(
        name: 'sftp_list_dir',
        description: 'List a remote directory through SFTP.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote directory path. Defaults to ".".'),
        },
        required: const ['connectionId'],
      ),
      _tool(
        name: 'sftp_read_text',
        description:
            'Read a small remote text file through SFTP. Binary and large files are rejected.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
        },
        required: const ['connectionId', 'path'],
      ),
    ];
  }

  Future<String> execute(String name, Map<String, dynamic> arguments) async {
    switch (name) {
      case 'list_servers':
        return _listServers();
      case 'run_command':
        return _runCommand(arguments);
      case 'sftp_list_dir':
        return _listDir(arguments);
      case 'sftp_read_text':
        return _readText(arguments);
      default:
        return jsonEncode({'error': 'Unknown tool: $name'});
    }
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
      'df ',
      'du ',
      'free',
      'head ',
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

  Map<String, dynamic> _tool({
    required String name,
    required String description,
    required Map<String, dynamic> properties,
    List<String> required = const [],
  }) {
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

  static Map<String, dynamic> _string(String description) {
    return {'type': 'string', 'description': description};
  }
}

const int _maxToolTextChars = 12000;
