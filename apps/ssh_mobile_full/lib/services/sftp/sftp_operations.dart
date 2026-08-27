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

  Future<Uint8List> _downloadPathForConnectionImpl({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {
    return _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      final attrs = await sftp.stat(absolutePath);
      if (attrs.isDirectory) {
        throw StateError('Directories cannot be downloaded');
      }
      _assertWithinMemoryLimit(attrs.size, 'download', maxBytes: maxBytes);

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
        return cachedBytes;
      }

      final transferId = '${config.id}-dl-${DateTime.now().millisecondsSinceEpoch}';
      final transfer = SftpTransferState(
        id: transferId,
        name: p.basename(absolutePath),
        totalBytes: attrs.size ?? 0,
        isUpload: false,
      );
      _startTransferTelemetry(transferId, transfer);
      SftpFile? file;
      try {
        file = await sftp.open(absolutePath, mode: SftpFileOpenMode.read);
        final bytes = await _readFileBytesWithinLimit(file, maxBytes: maxBytes);
        AppLogService.instance.info(
          'SFTP file downloaded for tool',
          details: SftpLogSafety.details(
            operation: 'tool_download',
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

        _completeTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: bytes.length),
        );
        return bytes;
      } catch (e) {
        _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: SftpService._mapSftpErrorCode(e, isUpload: false),
          stage: 'download',
          errorMessage: '$e',
        );
        rethrow;
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

  Future<void> _uploadBytesPathForConnectionImpl({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = SftpService.maxUploadBytes,
  }) async {
    _assertWithinMemoryLimit(bytes.length, 'upload', maxBytes: maxBytes);
    await _withDetachedSftp(connectionId, (sftp, config, targetBinding) async {
      final absolutePath = await sftp.absolute(path);
      final transferId = '${config.id}-up-${DateTime.now().millisecondsSinceEpoch}';
      final transfer = SftpTransferState(
        id: transferId,
        name: p.basename(absolutePath),
        totalBytes: bytes.length,
        isUpload: true,
      );
      _startTransferTelemetry(transferId, transfer);
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
          'SFTP file uploaded for tool',
          details: SftpLogSafety.details(
            operation: 'tool_upload',
            connectionId: config.id,
            path: absolutePath,
            bytes: bytes.length,
          ),
        );
        _completeTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: bytes.length),
        );
      } catch (e) {
        _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: SftpService._mapSftpErrorCode(e, isUpload: true),
          stage: 'upload',
          errorMessage: '$e',
        );
        rethrow;
      } finally {
        await _closeFileQuietly(file);
      }
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
}
