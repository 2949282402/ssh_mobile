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
}
