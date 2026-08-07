part of '../ai_tool_service.dart';

class SftpToolsProvider implements AiToolProvider {
  final SftpClientAdapter sftpService;
  final ClientSystemToolAdapter clientSystemToolService;

  const SftpToolsProvider({
    required this.sftpService,
    required this.clientSystemToolService,
  });

  @override
  Future<List<AiTool>> getTools(AiToolService service) async {
    return [
      AiTool(
        name: 'sftp_list_dir',
        description:
            'List a remote directory through detached SFTP. Secret-bearing paths are blocked by the tool secret policy.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote directory path. Defaults to ".".'),
        },
        required: const ['connectionId'],
        handler: (args) => _listDir(service, args),
      ),
      AiTool(
        name: 'sftp_get_entry_info',
        description:
            'Get detached SFTP metadata for one remote path. Secret-bearing paths are blocked by the tool secret policy.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote path.'),
        },
        required: const ['connectionId', 'path'],
        handler: (args) => _sftpGetEntryInfo(service, args),
      ),
      AiTool(
        name: 'sftp_read_text',
        description:
            'Read a small remote text file through detached SFTP after user approval. Binary and large files are rejected. Secret-bearing paths are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
        },
        required: const ['connectionId', 'path'],
        handler: (arguments) =>
            _readText(service, arguments, approvedRead: false),
      ),
      AiTool(
        name: 'sftp_download_file',
        description:
            'Download a remote file through detached SFTP and save it to the client device running SSH Mobile. The tool returns save metadata, not file content. Secret-bearing paths are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote file path.'),
        },
        required: const ['connectionId', 'path'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _sftpDownloadFile(service, arguments, approvedRead: false),
      ),
      AiTool(
        name: 'sftp_write_text',
        description:
            'Write a text file through detached SFTP by replacing or creating the remote file. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
          'content': _string('Full text content to write to the remote file.'),
        },
        required: const ['connectionId', 'path', 'content'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _sftpWriteText(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'sftp_upload_local_file',
        description:
            'Pick a local client file and upload it to a remote path through detached SFTP. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string(
            'Remote destination path. If it ends with "/" the picked local filename is appended.',
          ),
        },
        required: const ['connectionId', 'path'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _sftpUploadLocalFile(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'sftp_create_directory',
        description:
            'Create a remote directory through detached SFTP. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote directory path to create.'),
        },
        required: const ['connectionId', 'path'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _sftpCreateDirectory(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'sftp_rename_entry',
        description:
            'Rename or move a remote file or directory through detached SFTP. This changes remote state, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Current remote path.'),
          'newPath': _string('New remote path.'),
        },
        required: const ['connectionId', 'path', 'newPath'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _sftpRenameEntry(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'sftp_delete_entry',
        description:
            'Delete a remote file or empty directory through detached SFTP. This is destructive, requires user approval, and is blocked on secret-bearing paths.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote file or directory path.'),
        },
        required: const ['connectionId', 'path'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _sftpDeleteEntry(service, arguments, approvedWrite: false),
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
      case 'sftp_list_dir':
        return _listDir(service, arguments);
      case 'sftp_get_entry_info':
        return _sftpGetEntryInfo(service, arguments);
      case 'sftp_read_text':
        return _readText(service, arguments, approvedRead: approvedWrite);
      case 'sftp_download_file':
        return _sftpDownloadFile(
          service,
          arguments,
          approvedRead: approvedWrite,
        );
      case 'sftp_write_text':
        return _sftpWriteText(service, arguments, approvedWrite: approvedWrite);
      case 'sftp_upload_local_file':
        return _sftpUploadLocalFile(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'sftp_create_directory':
        return _sftpCreateDirectory(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'sftp_rename_entry':
        return _sftpRenameEntry(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'sftp_delete_entry':
        return _sftpDeleteEntry(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      default:
        return null;
    }
  }

  Future<String> _listDir(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._optionalString(arguments, 'path') ?? '.';
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    final entries = await sftpService.listDirectoryForConnection(
      connectionId,
      path,
    );
    return jsonEncode({
      'path': path,
      'entries': entries
          .take(200)
          .map(
            (entry) => {
              'name': entry.name,
              'path': entry.path,
              'type': entry.isDirectory ? 'directory' : 'file',
              'isLink': entry.isLink,
              'size': entry.size,
              'sizeLabel': entry.sizeLabel,
              'modifiedAt': entry.modifiedAt?.toIso8601String(),
              'modifiedLabel': entry.modifiedLabel,
            },
          )
          .toList(),
      if (entries.length > 200) 'truncated': true,
    });
  }

  Future<String> _sftpGetEntryInfo(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    final path = service._arg(arguments, 'path');
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    final info = await sftpService.statPathForConnection(
      connectionId: service._arg(arguments, 'connectionId'),
      path: path,
    );
    return jsonEncode(info.toJson());
  }

  Future<String> _readText(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedRead,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._arg(arguments, 'path');
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedRead) {
      return jsonEncode({
        'error': 'Remote file read requires user approval before execution.',
        'path': path,
      });
    }
    final text = await sftpService.readTextPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({
      'path': path,
      'content': service._truncate(text),
      'truncated': text.length > AiToolService._maxToolTextChars,
    });
  }

  Future<String> _sftpDownloadFile(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedRead,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._arg(arguments, 'path');
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedRead) {
      return jsonEncode({
        'error':
            'Remote file download requires user approval before execution.',
        'path': path,
      });
    }
    final bytes = await sftpService.downloadPathForConnection(
      connectionId: connectionId,
      path: path,
      maxBytes: service._sftpDownloadLimitBytes,
    );
    final saveResult = await clientSystemToolService.saveBytesToFile(
      fileName: service._remoteFileName(path),
      bytes: bytes,
      dialogTitle: 'Download file',
    );
    return jsonEncode({...saveResult, 'remotePath': path});
  }

  Future<String> _sftpWriteText(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._arg(arguments, 'path');
    final content = service._arg(arguments, 'content');
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote file write requires user approval before execution.',
        'path': path,
      });
    }
    final bytes = utf8.encode(content).length;
    await sftpService.writeTextPathForConnection(
      connectionId: connectionId,
      path: path,
      text: content,
      maxBytes: service._sftpTextEditLimitBytes,
    );
    return jsonEncode({'path': path, 'bytes': bytes, 'written': true});
  }

  Future<String> _sftpUploadLocalFile(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._arg(arguments, 'path');
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote file upload requires user approval before execution.',
        'path': path,
      });
    }
    final picked = await clientSystemToolService.pickFile(
      dialogTitle: 'Upload local file',
    );
    if (picked == null) {
      return jsonEncode({
        'uploaded': false,
        'cancelled': true,
        'note': 'The user cancelled the local file picker.',
      });
    }
    final remotePath = _resolveRemoteUploadPath(path, picked.name);
    final remoteBlocked = service._secretPathBlocked(remotePath);
    if (remoteBlocked != null) return remoteBlocked;
    await sftpService.uploadBytesPathForConnection(
      connectionId: connectionId,
      path: remotePath,
      bytes: picked.bytes,
    );
    return jsonEncode({
      'uploaded': true,
      'cancelled': false,
      'remotePath': remotePath,
      'fileName': picked.name,
      'bytes': picked.bytes.length,
    });
  }

  Future<String> _sftpCreateDirectory(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._arg(arguments, 'path');
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote directory creation requires user approval.',
        'path': path,
      });
    }
    await sftpService.createDirectoryPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({'created': true, 'path': path});
  }

  Future<String> _sftpRenameEntry(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._arg(arguments, 'path');
    final newPath = service._arg(arguments, 'newPath');
    final blocked =
        service._secretPathBlocked(path) ?? service._secretPathBlocked(newPath);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote rename or move requires user approval.',
        'path': path,
        'newPath': newPath,
      });
    }
    await sftpService.renamePathForConnection(
      connectionId: connectionId,
      path: path,
      newPath: newPath,
    );
    return jsonEncode({'renamed': true, 'path': path, 'newPath': newPath});
  }

  Future<String> _sftpDeleteEntry(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = service._arg(arguments, 'connectionId');
    final path = service._arg(arguments, 'path');
    final blocked = service._secretPathBlocked(path);
    if (blocked != null) return blocked;
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Remote delete requires user approval.',
        'path': path,
      });
    }
    await sftpService.deletePathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({'deleted': true, 'path': path});
  }

  String _resolveRemoteUploadPath(String requestedPath, String pickedName) {
    final trimmed = requestedPath.trim();
    if (trimmed.isEmpty) return pickedName;
    if (trimmed.endsWith('/')) return '$trimmed$pickedName';
    return trimmed;
  }
}
