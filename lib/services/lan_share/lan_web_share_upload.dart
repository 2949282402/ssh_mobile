part of 'lan_discovery_service.dart';

extension _LanWebShareUploadOperations on LanDiscoveryService {
  Future<Uint8List> _readBoundedWebBody(
    HttpRequest request, {
    required int maxBytes,
  }) async {
    if (request.contentLength > maxBytes) {
      throw const _WebShareHttpException(
        HttpStatus.requestEntityTooLarge,
        'Request body is too large.',
      );
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > maxBytes) {
        throw const _WebShareHttpException(
          HttpStatus.requestEntityTooLarge,
          'Request body is too large.',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Map<String, dynamic> _decodeWebJson(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected an object.');
      }
      return decoded;
    } on FormatException {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'Malformed Web Share metadata.',
      );
    }
  }

  bool _isEncryptedWebRequest(HttpRequest request) {
    final value = request.headers.value('x-e2e-pubkey');
    if (value == null) return false;
    if (value == '1') return true;
    throw const _WebShareHttpException(
      HttpStatus.badRequest,
      'Invalid encryption header.',
    );
  }

  Future<Uint8List> _decryptWebPayload(
    Uint8List encrypted,
    LanSecurityService securityService,
  ) async {
    try {
      return await securityService.decryptE2E(encrypted);
    } catch (_) {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'Invalid encrypted payload.',
      );
    }
  }

  String _validatedWebMessageId(Object? value) {
    final messageId = value is String ? value.trim() : '';
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(messageId)) {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'Invalid Web Share message ID.',
      );
    }
    return messageId;
  }

  String _validatedWebFileName(Object? value) {
    final fileName = value is String ? value.trim() : '';
    if (fileName.isEmpty ||
        fileName.length > 255 ||
        fileName == '.' ||
        fileName == '..' ||
        RegExp(r'[\x00-\x1F/\\]').hasMatch(fileName)) {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'Invalid Web Share file name.',
      );
    }
    return fileName;
  }

  String _decodeWebFileNameHeader(String? value) {
    if (value == null || value.length > 1024) {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'A valid file name header is required.',
      );
    }
    try {
      return _validatedWebFileName(Uri.decodeComponent(value));
    } on _WebShareHttpException {
      rethrow;
    } catch (_) {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'Invalid encoded file name.',
      );
    }
  }

  void _prunePendingWebUploads() {
    _pendingWebUploads.removeWhere((_, upload) => upload.isExpired);
  }

  Future<void> _handleWebMetaRequest(
    HttpRequest request,
    LanSecurityService securityService,
    LanTransferService transferService,
    LanStorageService storageService,
  ) async {
    _LanWebShareServerOperations(this)._requireWebShareToken(request);
    final encrypted = _isEncryptedWebRequest(request);
    final rawBody = await _readBoundedWebBody(
      request,
      maxBytes:
          LanTransferProtocolGuard.maxControlBodyBytes +
          (encrypted ? LanDiscoveryService._e2eEnvelopeOverheadBytes : 0),
    );
    final plainBody = encrypted
        ? await _decryptWebPayload(rawBody, securityService)
        : rawBody;
    if (plainBody.length > LanTransferProtocolGuard.maxControlBodyBytes) {
      throw const _WebShareHttpException(
        HttpStatus.requestEntityTooLarge,
        'Web Share metadata is too large.',
      );
    }

    final json = _decodeWebJson(plainBody);
    final messageId = _validatedWebMessageId(json['id']);
    final fileName = _validatedWebFileName(json['fileName']);
    final senderId = json['senderId'];
    final receiverId = json['receiverId'];
    final payloadType = json['payloadType'];
    final rawFileSize = json['fileSize'];
    if (senderId != 'web-browser' ||
        receiverId != currentDeviceId ||
        payloadType != LanPayloadType.file.toJson() ||
        rawFileSize is! num ||
        !rawFileSize.isFinite ||
        rawFileSize != rawFileSize.toInt()) {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'Invalid Web Share metadata.',
      );
    }
    final fileSize = rawFileSize.toInt();
    if (fileSize < 0 ||
        fileSize > LanTransferProtocolGuard.maxAdvertisedFileBytes ||
        (encrypted &&
            fileSize > LanTransferProtocolGuard.maxEncryptedUploadBytes)) {
      throw const _WebShareHttpException(
        HttpStatus.requestEntityTooLarge,
        'Web Share file exceeds the allowed size.',
      );
    }

    _prunePendingWebUploads();
    if (_pendingWebUploads.containsKey(messageId)) {
      throw const _WebShareHttpException(
        HttpStatus.conflict,
        'A Web Share upload with this ID is already pending.',
      );
    }
    if (_pendingWebUploads.length >=
        LanDiscoveryService._maxPendingWebUploads) {
      throw const _WebShareHttpException(
        HttpStatus.tooManyRequests,
        'Too many Web Share uploads are pending.',
      );
    }
    if (!await storageService.hasSufficientSpace(fileSize)) {
      throw const _WebShareHttpException(
        HttpStatus.insufficientStorage,
        'Insufficient storage.',
      );
    }

    final message = LanMessage(
      id: messageId,
      senderId: 'web-browser',
      senderAlias: '网页端浏览器',
      receiverId: currentDeviceId,
      payloadType: LanPayloadType.file,
      fileName: fileName,
      fileSize: fileSize,
      status: LanTransferStatus.pending,
      bytesTransferred: 0,
      createdAt: DateTime.now(),
      isIncoming: true,
    );
    _pendingWebUploads[messageId] = _PendingWebUpload(
      messageId: messageId,
      fileName: fileName,
      expectedBytes: fileSize,
      encrypted: encrypted,
      expiresAt: DateTime.now().add(LanDiscoveryService._pendingWebUploadTtl),
    );
    try {
      transferService.handleIncomingMessageFromWeb(message);
    } catch (_) {
      _pendingWebUploads.remove(messageId);
      rethrow;
    }

    await _LanWebShareServerOperations(this)._writeWebShareJson(
      request.response,
      HttpStatus.ok,
      {'accepted': true, 'id': message.id},
    );
  }

  Future<void> _handleWebUploadRequest(
    HttpRequest request,
    LanSecurityService securityService,
    LanTransferService transferService,
    LanStorageService storageService,
  ) async {
    _LanWebShareServerOperations(this)._requireWebShareToken(request);
    final messageId = _validatedWebMessageId(
      request.headers.value('x-message-id'),
    );
    final fileName = _decodeWebFileNameHeader(
      request.headers.value('x-file-name'),
    );
    final encrypted = _isEncryptedWebRequest(request);
    _prunePendingWebUploads();
    final pending = _pendingWebUploads[messageId];
    if (pending == null) {
      throw const _WebShareHttpException(
        HttpStatus.conflict,
        'Upload metadata is missing or expired.',
      );
    }
    if (pending.fileName != fileName || pending.encrypted != encrypted) {
      throw const _WebShareHttpException(
        HttpStatus.badRequest,
        'Upload does not match its accepted metadata.',
      );
    }

    final expectedBodyBytes =
        pending.expectedBytes +
        (encrypted ? LanDiscoveryService._e2eEnvelopeOverheadBytes : 0);
    final declaredLength = request.contentLength;
    if (declaredLength >= 0 && declaredLength != expectedBodyBytes) {
      throw _WebShareHttpException(
        declaredLength > expectedBodyBytes
            ? HttpStatus.requestEntityTooLarge
            : HttpStatus.badRequest,
        'Upload length does not match its accepted metadata.',
      );
    }

    // Remove before the first await so concurrent requests cannot consume the
    // same accepted metadata twice.
    _pendingWebUploads.remove(messageId);
    File? targetFile;
    var completed = false;
    var bytesReceived = 0;
    try {
      targetFile = await storageService.getSandboxTargetFile(fileName);
      if (encrypted) {
        final encryptedBody = await _readBoundedWebBody(
          request,
          maxBytes: expectedBodyBytes,
        );
        if (encryptedBody.length != expectedBodyBytes) {
          throw const _WebShareHttpException(
            HttpStatus.badRequest,
            'Encrypted upload is incomplete.',
          );
        }
        final plainBytes = await _decryptWebPayload(
          encryptedBody,
          securityService,
        );
        if (plainBytes.length != pending.expectedBytes) {
          throw const _WebShareHttpException(
            HttpStatus.badRequest,
            'Decrypted upload length does not match metadata.',
          );
        }
        await targetFile.writeAsBytes(plainBytes, flush: true);
        bytesReceived = plainBytes.length;
      } else {
        final sink = targetFile.openWrite();
        try {
          await for (final chunk in request) {
            bytesReceived += chunk.length;
            if (bytesReceived > pending.expectedBytes) {
              throw const _WebShareHttpException(
                HttpStatus.requestEntityTooLarge,
                'Upload exceeds its accepted size.',
              );
            }
            sink.add(chunk);
          }
          if (bytesReceived != pending.expectedBytes) {
            throw const _WebShareHttpException(
              HttpStatus.badRequest,
              'Upload is incomplete.',
            );
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      }

      final completedMessage = LanMessage(
        id: pending.messageId,
        senderId: 'web-browser',
        senderAlias: '网页端浏览器',
        receiverId: currentDeviceId,
        payloadType: LanPayloadType.file,
        fileName: pending.fileName,
        localPath: targetFile.path,
        bytesTransferred: bytesReceived,
        fileSize: pending.expectedBytes,
        status: LanTransferStatus.completed,
        createdAt: DateTime.now(),
        isIncoming: true,
      );
      transferService.handleMessageProgressFromWeb(completedMessage);
      completed = true;

      await _LanWebShareServerOperations(this)._writeWebShareJson(
        request.response,
        HttpStatus.ok,
        {'success': true, 'id': messageId, 'bytesReceived': bytesReceived},
      );
    } catch (_) {
      if (!completed) {
        transferService.handleMessageProgressFromWeb(
          LanMessage(
            id: pending.messageId,
            senderId: 'web-browser',
            senderAlias: '网页端浏览器',
            receiverId: currentDeviceId,
            payloadType: LanPayloadType.file,
            fileName: pending.fileName,
            localPath: null,
            bytesTransferred: bytesReceived,
            fileSize: pending.expectedBytes,
            status: LanTransferStatus.failed,
            createdAt: DateTime.now(),
            isIncoming: true,
          ),
        );
      }
      rethrow;
    } finally {
      if (!completed && targetFile != null) {
        try {
          await storageService.deleteSandboxFile(targetFile.path);
        } catch (_) {}
      }
    }
  }
}
