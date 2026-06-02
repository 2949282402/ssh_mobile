part of '../ai_tool_service.dart';

extension _SftpTools on AiToolService {
  Future<String> _listDir(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _optionalString(arguments, 'path') ?? '.';
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final entries =
        await sftpService.listDirectoryForConnection(connectionId, path);
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

  Future<String> _sftpGetEntryInfo(Map<String, dynamic> arguments) async {
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final info = await sftpService.statPathForConnection(
      connectionId: _arg(arguments, 'connectionId'),
      path: path,
    );
    return jsonEncode(info.toJson());
  }

  Future<String> _readText(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final text = await sftpService.readTextPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({
      'path': path,
      'content': _truncate(text),
      'truncated': text.length > AiToolService._maxToolTextChars,
    });
  }

  Future<String> _sftpDownloadFile(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
    if (blocked != null) return blocked;
    final bytes = await sftpService.downloadPathForConnection(
      connectionId: connectionId,
      path: path,
      maxBytes: _sftpDownloadLimitBytes,
    );
    final saveResult = await clientSystemToolService.saveBytesToFile(
      fileName: _remoteFileName(path),
      bytes: bytes,
      dialogTitle: 'Download file',
    );
    return jsonEncode({
      ...saveResult,
      'remotePath': path,
    });
  }

  Future<String> _sftpWriteText(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final content = _arg(arguments, 'content');
    final blocked = _secretPathBlocked(path);
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
      maxBytes: _sftpTextEditLimitBytes,
    );
    return jsonEncode({
      'path': path,
      'bytes': bytes,
      'written': true,
    });
  }

  Future<String> _sftpUploadLocalFile(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
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
    final remoteBlocked = _secretPathBlocked(remotePath);
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
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
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
    return jsonEncode({
      'created': true,
      'path': path,
    });
  }

  Future<String> _sftpRenameEntry(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final newPath = _arg(arguments, 'newPath');
    final blocked = _secretPathBlocked(path) ?? _secretPathBlocked(newPath);
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
    return jsonEncode({
      'renamed': true,
      'path': path,
      'newPath': newPath,
    });
  }

  Future<String> _sftpDeleteEntry(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final blocked = _secretPathBlocked(path);
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
    return jsonEncode({
      'deleted': true,
      'path': path,
    });
  }

  String _resolveRemoteUploadPath(String requestedPath, String pickedName) {
    final trimmed = requestedPath.trim();
    if (trimmed.isEmpty) return pickedName;
    if (trimmed.endsWith('/')) return '$trimmed$pickedName';
    return trimmed;
  }

  List<AiTool> _getSftpTools() {
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
        handler: _listDir,
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
        handler: _sftpGetEntryInfo,
      ),
      AiTool(
        name: 'sftp_read_text',
        description:
            'Read a small remote text file through detached SFTP. Binary and large files are rejected. Secret-bearing paths are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
        },
        required: const ['connectionId', 'path'],
        handler: _readText,
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
        handler: _sftpDownloadFile,
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
        handler: (arguments) => _sftpWriteText(arguments, approvedWrite: false),
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
        handler: (arguments) => _sftpUploadLocalFile(
          arguments,
          approvedWrite: false,
        ),
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
        handler: (arguments) => _sftpCreateDirectory(
          arguments,
          approvedWrite: false,
        ),
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
        handler: (arguments) => _sftpRenameEntry(
          arguments,
          approvedWrite: false,
        ),
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
        handler: (arguments) => _sftpDeleteEntry(
          arguments,
          approvedWrite: false,
        ),
      ),
    ];
  }
}
