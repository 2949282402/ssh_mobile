part of 'sftp_service_io.dart';

/// Owns bounded downloads for the active session and detached tool calls.
extension SftpServiceTransferDownloads on SftpService {
  Future<void> _downloadFileImpl(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    if (entry.isDirectory) throw StateError('Directories cannot be downloaded');

    final totalSize = entry.size ?? 0;
    if (totalSize > 0) {
      _assertWithinMemoryLimit(totalSize, 'download', maxBytes: maxBytes);
    }

    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    final transfer = SftpTransferState(
      id: transferId,
      name: entry.name,
      totalBytes: totalSize,
      isUpload: false,
    );
    _activeTransfer = transfer;
    _cancelTransferId = null;
    session.state = SftpConnectionState.loading;
    notifyListeners();
    _startTransferTelemetry(transferId, transfer);

    RandomAccessFile? raf;
    SftpFile? remoteFile;
    var shouldDeletePartialLocalFile = false;
    try {
      final localFile = File(localPath);
      final parentDir = localFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      raf = await localFile.open(mode: FileMode.write);
      remoteFile = await sftp.open(entry.path, mode: SftpFileOpenMode.read);

      const chunkSize = 256 * 1024; // 256KB chunks
      int offset = 0;

      while (totalSize == 0 || offset < totalSize) {
        if (_cancelTransferId == transferId) {
          throw const SftpTransferCancelledException();
        }

        final len = (totalSize > 0 && (totalSize - offset) < chunkSize)
            ? (totalSize - offset)
            : chunkSize;
        final chunk = await remoteFile.readBytes(length: len, offset: offset);
        if (chunk.isEmpty) break;

        if (offset + chunk.length > maxBytes) {
          throw StateError(
            'Download exceeds max size of ${_formatBytes(maxBytes)}',
          );
        }

        await raf.writeFrom(chunk);
        offset += chunk.length;

        _activeTransfer = transfer.copyWith(bytesTransferred: offset);
        notifyListeners();
      }

      AppLogService.instance.info(
        'SFTP file downloaded via stream',
        details: SftpLogSafety.details(
          operation: 'stream_download',
          connectionId: entry.connectionId,
          path: entry.path,
          destinationPath: localPath,
          bytes: offset,
        ),
      );

      session.state = SftpConnectionState.connected;
      notifyListeners();
      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: offset),
      );
    } catch (e) {
      shouldDeletePartialLocalFile = true;

      if (e is SftpTransferCancelledException) {
        AppLogService.instance.info(
          'SFTP download cancelled',
          details: SftpLogSafety.details(
            operation: 'stream_download_cancelled',
            connectionId: entry.connectionId,
            path: entry.path,
            destinationPath: localPath,
          ),
        );
        session.state = SftpConnectionState.connected;
        await _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: TelemetryErrorCodes.sftpTransferAborted,
          stage: 'download',
          errorMessage: 'Transfer cancelled by user',
        );
      } else {
        AppLogService.instance.error(
          'SFTP download failed',
          details: SftpLogSafety.details(
            operation: 'stream_download',
            connectionId: entry.connectionId,
            path: entry.path,
            destinationPath: localPath,
            error: e,
          ),
        );
        session.state = SftpConnectionState.error;
        session.errorMessage = 'Download failed: $e';
        await _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: _mapSftpErrorCode(e, isUpload: false),
          stage: 'download',
          errorMessage: '$e',
        );
      }
      notifyListeners();
      rethrow;
    } finally {
      await raf?.close();
      await _closeFileQuietly(remoteFile);

      // Close the local handle before deleting a partial file on Windows.
      if (shouldDeletePartialLocalFile) {
        try {
          final file = File(localPath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }

      _activeTransfer = null;
      _cancelTransferId = null;
      notifyListeners();
    }
  }

  Future<Uint8List> _downloadBytesImpl(
    SftpEntry entry, {
    int maxBytes = SftpService.maxDownloadBytes,
    bool updateState = false,
    bool bypassCache = false,
  }) async {
    final session = _sessionForEntry(entry);
    final sftp = session.sftp;
    if (sftp == null) throw StateError('SFTP is not connected');
    if (entry.isDirectory) throw StateError('Directories cannot be downloaded');
    _assertWithinMemoryLimit(entry.size, 'download', maxBytes: maxBytes);

    if (!bypassCache) {
      final cachedBytes = await SftpFileCache.get(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
        entry.size,
        entry.modifiedAt,
        maxBytes: maxBytes,
      );
      if (cachedBytes != null) {
        return cachedBytes;
      }
    }

    if (updateState) {
      session.state = SftpConnectionState.loading;
      session.errorMessage = null;
      notifyListeners();
    }

    final transferId =
        '${entry.connectionId}-${DateTime.now().millisecondsSinceEpoch}';
    final transfer = SftpTransferState(
      id: transferId,
      name: entry.name,
      totalBytes: entry.size ?? 0,
      isUpload: false,
    );
    _startTransferTelemetry(transferId, transfer);
    SftpFile? file;
    try {
      file = await sftp.open(entry.path, mode: SftpFileOpenMode.read);
      final bytes = await _readFileBytesWithinLimit(file, maxBytes: maxBytes);
      AppLogService.instance.info(
        'SFTP file downloaded',
        details: SftpLogSafety.details(
          operation: 'download_bytes',
          connectionId: entry.connectionId,
          path: entry.path,
          bytes: bytes.length,
        ),
      );

      await SftpFileCache.put(
        entry.connectionId,
        session.targetFingerprint,
        entry.path,
        entry.size,
        entry.modifiedAt,
        bytes,
      );

      _completeTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: bytes.length),
      );
      if (updateState) {
        session.state = SftpConnectionState.connected;
        notifyListeners();
      }
      return bytes;
    } catch (e) {
      AppLogService.instance.error(
        'SFTP download failed',
        details: SftpLogSafety.details(
          operation: 'download_bytes',
          connectionId: entry.connectionId,
          path: entry.path,
          error: e,
        ),
      );
      await _failTransferTelemetry(
        transferId,
        transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
        errorCode: _mapSftpErrorCode(e, isUpload: false),
        stage: 'download',
        errorMessage: '$e',
      );
      if (updateState) {
        session.state = SftpConnectionState.error;
        session.errorMessage = 'Download failed: $e';
        notifyListeners();
      }
      rethrow;
    } finally {
      await _closeFileQuietly(file);
    }
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

      final transferId =
          '${config.id}-dl-${DateTime.now().millisecondsSinceEpoch}';
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
        await _failTransferTelemetry(
          transferId,
          transfer.copyWith(bytesTransferred: transfer.bytesTransferred),
          errorCode: _mapSftpErrorCode(e, isUpload: false),
          stage: 'download',
          errorMessage: '$e',
        );
        rethrow;
      } finally {
        await _closeFileQuietly(file);
      }
    });
  }
}
