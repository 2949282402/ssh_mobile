part of 'sftp_service_io.dart';

extension SftpServiceOperations on SftpService {
  Future<List<SftpEntry>> _listDirectoryForConnectionImpl(
    String connectionId,
    String path,
  ) async {
    return _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);

      final cached = _directoryCache.get(
        connectionId,
        targetBinding.fingerprint,
        absolutePath,
      );
      if (cached != null) {
        return cached;
      }

      final names = await sftp.listdir(absolutePath);
      final entries = await _buildEntries(
        connectionId: config.id,
        targetFingerprint: targetBinding.fingerprint,
        absolutePath: absolutePath,
        names: names,
      );
      final unmodifiableEntries = List<SftpEntry>.unmodifiable(entries);
      _directoryCache.set(
        connectionId,
        targetBinding.fingerprint,
        absolutePath,
        unmodifiableEntries,
      );
      AppLogService.instance.info(
        'SFTP directory listed for tool',
        details: SftpLogSafety.details(
          operation: 'tool_list_directory',
          connectionId: config.id,
          path: absolutePath,
        ),
      );
      return unmodifiableEntries;
    });
  }

  Future<String> _readTextPathForConnectionImpl({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxTextPreviewBytes,
  }) async {
    return _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      final attrs = await sftp.stat(absolutePath);
      _assertWithinMemoryLimit(attrs.size, 'read', maxBytes: maxBytes);
      final modifiedAt = attrs.modifyTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000);

      final cachedBytes = await SftpFileCache.get(
        connectionId,
        targetBinding.fingerprint,
        absolutePath,
        attrs.size,
        modifiedAt,
        maxBytes: maxBytes,
      );
      if (cachedBytes != null) {
        return compute(SftpService._decodeUtf8, cachedBytes);
      }

      SftpFile? file;
      try {
        file = await sftp.open(absolutePath, mode: SftpFileOpenMode.read);
        final bytes = await _readFileBytesWithinLimit(file, maxBytes: maxBytes);
        AppLogService.instance.info(
          'SFTP file read for tool',
          details: SftpLogSafety.details(
            operation: 'tool_read_text',
            connectionId: config.id,
            path: absolutePath,
            bytes: bytes.length,
          ),
        );

        await SftpFileCache.put(
          connectionId,
          targetBinding.fingerprint,
          absolutePath,
          attrs.size,
          modifiedAt,
          bytes,
        );

        return await compute(SftpService._decodeUtf8, bytes);
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }

  Future<void> _writeTextPathForConnectionImpl({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    _assertWithinMemoryLimit(bytes.length, 'edit', maxBytes: maxBytes);
    await _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      SftpFile? file;
      try {
        file = await sftp.open(
          absolutePath,
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        await file.writeBytes(bytes);
        _directoryCache.invalidate(connectionId, targetBinding.fingerprint);
        await SftpFileCache.invalidate(
          connectionId,
          targetBinding.fingerprint,
          absolutePath,
        );
        AppLogService.instance.info(
          'SFTP text file saved for tool',
          details: SftpLogSafety.details(
            operation: 'tool_write_text',
            connectionId: config.id,
            path: absolutePath,
            bytes: bytes.length,
          ),
        );
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }

  Future<SftpPathInfo> _statPathForConnectionImpl({
    required String connectionId,
    required String path,
  }) async {
    return _withDetachedSftp(connectionId, (sftp, _, _) async {
      final absolutePath = await sftp.absolute(path);
      final attrs = await sftp.stat(absolutePath);
      final modifiedAt = attrs.modifyTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000);
      return SftpPathInfo(
        path: absolutePath,
        isDirectory: attrs.isDirectory,
        isLink: attrs.isSymbolicLink,
        size: attrs.size,
        sizeLabel: _formatBytes(attrs.size),
        modifiedAt: modifiedAt,
      );
    });
  }

  Future<void> _createDirectoryPathForConnectionImpl({
    required String connectionId,
    required String path,
  }) async {
    await _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      await sftp.mkdir(absolutePath);
      _directoryCache.invalidate(connectionId, targetBinding.fingerprint);
      AppLogService.instance.info(
        'SFTP directory created for tool',
        details: SftpLogSafety.details(
          operation: 'tool_create_directory',
          connectionId: config.id,
          path: absolutePath,
        ),
      );
    });
  }

  Future<void> _renamePathForConnectionImpl({
    required String connectionId,
    required String path,
    required String newPath,
  }) async {
    await _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      final absoluteNewPath = await sftp.absolute(newPath);
      await sftp.rename(absolutePath, absoluteNewPath);
      _directoryCache.invalidate(connectionId, targetBinding.fingerprint);
      await SftpFileCache.invalidate(
        connectionId,
        targetBinding.fingerprint,
        absolutePath,
      );
      await SftpFileCache.invalidate(
        connectionId,
        targetBinding.fingerprint,
        absoluteNewPath,
      );
      AppLogService.instance.info(
        'SFTP path renamed for tool',
        details: SftpLogSafety.details(
          operation: 'tool_rename',
          connectionId: config.id,
          path: absolutePath,
          destinationPath: absoluteNewPath,
        ),
      );
    });
  }

  Future<void> _deletePathForConnectionImpl({
    required String connectionId,
    required String path,
  }) async {
    await _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      final attrs = await sftp.stat(absolutePath);
      if (attrs.isDirectory) {
        await sftp.rmdir(absolutePath);
      } else {
        await sftp.remove(absolutePath);
      }
      _directoryCache.invalidate(connectionId, targetBinding.fingerprint);
      await SftpFileCache.invalidate(
        connectionId,
        targetBinding.fingerprint,
        absolutePath,
      );
      AppLogService.instance.info(
        'SFTP path deleted for tool',
        details: SftpLogSafety.details(
          operation: 'tool_delete',
          connectionId: config.id,
          path: absolutePath,
          directory: attrs.isDirectory,
        ),
      );
    });
  }

  Future<void> _deleteEntryImpl(
    SftpEntry entry, {
    required String confirmedName,
  }) async {
    if (confirmedName != entry.name && confirmedName.trim() != entry.name) {
      throw StateError('Deletion confirmation does not match the entry name.');
    }
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) return;

    session.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    try {
      if (entry.isDirectory) {
        await sftp.rmdir(entry.path);
      } else {
        await sftp.remove(entry.path);
      }
      _directoryCache.invalidate(entry.connectionId, session.targetFingerprint);
      await SftpFileCache.invalidate(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
      );
      AppLogService.instance.info(
        'SFTP entry deleted',
        details: SftpLogSafety.details(
          operation: 'delete_entry',
          connectionId: entry.connectionId,
          path: entry.path,
          directory: entry.isDirectory,
        ),
      );
      await _openPath(session, session.currentPath);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP delete failed',
        details: SftpLogSafety.details(
          operation: 'delete_entry',
          connectionId: entry.connectionId,
          path: entry.path,
          directory: entry.isDirectory,
          error: e,
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Delete failed: $e';
      notifyListeners();
    }
  }

  Future<String> _readTextFileImpl(
    SftpEntry entry, {
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {
    final sftp = _sessionForEntry(entry).sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    _assertWithinMemoryLimit(entry.size, 'edit', maxBytes: maxBytes);

    SftpFile? file;
    try {
      file = await sftp.open(entry.path, mode: SftpFileOpenMode.read);
      final bytes = await _readFileBytesWithinLimit(file, maxBytes: maxBytes);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await _closeFileQuietly(file);
    }
  }

  Future<void> _saveTextFileImpl(
    SftpEntry entry,
    String text, {
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > maxBytes) {
      throw SftpTextSizeLimitException(
        actualBytes: bytes.length,
        maxBytes: maxBytes,
      );
    }

    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');

    session.state = SftpConnectionState.loading;
    session.errorMessage = null;
    notifyListeners();

    SftpFile? file;
    try {
      file = await sftp.open(
        entry.path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      await file.writeBytes(bytes);
      await _closeFileQuietly(file);
      file = null;
      _directoryCache.invalidate(entry.connectionId, session.targetFingerprint);
      await SftpFileCache.invalidate(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
      );
      AppLogService.instance.info(
        'SFTP text file saved',
        details: SftpLogSafety.details(
          operation: 'save_text',
          connectionId: entry.connectionId,
          path: entry.path,
          bytes: bytes.length,
        ),
      );
      await _openPath(session, session.currentPath, bypassCache: true);
    } catch (e) {
      AppLogService.instance.error(
        'SFTP save failed',
        details: SftpLogSafety.details(
          operation: 'save_text',
          connectionId: entry.connectionId,
          path: entry.path,
          error: e,
        ),
      );
      session.state = SftpConnectionState.error;
      session.errorMessage = 'Save failed: $e';
      notifyListeners();
      rethrow;
    } finally {
      await _closeFileQuietly(file);
    }
  }
}
