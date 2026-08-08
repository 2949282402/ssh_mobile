// v1 LAN HTTPS 客户端的配对、元数据、文件传输和撤回操作。
// 使用 part 文件与服务端实现分离，确保源码低于仓库 1000 行维护上限。

part of 'lan_transfer_service.dart';

/// 保存服务端返回且已通过绑定校验的配对凭据。
class _ValidatedPairingCredential {
  final String accessToken;
  final String certFingerprint;
  final String status;

  const _ValidatedPairingCredential({
    required this.accessToken,
    required this.certFingerprint,
    required this.status,
  });
}

/// 保存通过 SPAKE2/证书校验的临时配对 offer。
class _AcceptedPairingOffer {
  final String handshakeId;
  final LanPairingSessionSecrets sessionSecrets;
  final String certFingerprint;

  const _AcceptedPairingOffer({
    required this.handshakeId,
    required this.sessionSecrets,
    required this.certFingerprint,
  });
}

extension LanTransferClientApi on LanTransferService {
  /// 创建配置为连接一个已配对对端的 HTTP 客户端。
  Future<HttpClient> createHttpClientForPeer(String peerDeviceId) {
    return _createHttpClient(peerDeviceId: peerDeviceId);
  }

  /// 读取并限制 JSON 响应大小，不向上层暴露原始服务端细节。
  Future<Map<String, dynamic>> readBoundedJsonResponse(
    HttpClientResponse response, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await response
        .forEach((chunk) {
          total += chunk.length;
          if (total > LanTransferProtocolGuard.maxControlBodyBytes) {
            throw LanNetworkException('LAN response body is too large.');
          }
          bytes.add(chunk);
        })
        .timeout(timeout);
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      throw LanNetworkException('LAN response is not a JSON object.');
    }
    return decoded;
  }

  /// 添加所有配对后 LAN API 必需的配对专属凭据。
  Future<NetworkResult<void>> addPairingAuthorization(
    HttpHeaders headers,
    String peerDeviceId,
  ) async {
    final token = await securityService.getOutboundAccessToken(peerDeviceId);
    if (token == null || token.isEmpty) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'LAN pairing credentials are unavailable.',
          operation: NetworkOperation.authorizeLanRequest,
          peerId: peerDeviceId,
        ),
      );
    }
    headers.set('x-device-id', currentDeviceId);
    headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    return const NetworkSuccess<void>(null);
  }

  /// 校验配对凭据的会话、设备、请求摘要和有效期绑定。
  _ValidatedPairingCredential _validatePairingCredential(
    Map<String, dynamic> credential, {
    required String expectedNonce,
    required String expectedHandshakeId,
    required String expectedRequestHash,
    required String expectedIssuerDeviceId,
    required String expectedRecipientDeviceId,
    required Duration elapsed,
  }) {
    final protocolVersion = credential['protocolVersion'];
    final accessToken = credential['accessToken'];
    final fingerprint = credential['certFingerprint'];
    final status = credential['status'];
    final requestNonce = credential['requestNonce'];
    final handshakeId = credential['handshakeId'];
    final requestHash = credential['requestHash'];
    final issuerDeviceId = credential['issuerDeviceId'];
    final recipientDeviceId = credential['recipientDeviceId'];
    final validForMs = credential['validForMs'];

    if (protocolVersion != LanPairingCrypto.protocolVersion ||
        accessToken is! String ||
        accessToken.isEmpty ||
        accessToken.length > 256 ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fingerprint) ||
        (status != 'pending_remote' && status != 'paired') ||
        requestNonce != expectedNonce ||
        handshakeId != expectedHandshakeId ||
        requestHash != expectedRequestHash ||
        issuerDeviceId != expectedIssuerDeviceId ||
        recipientDeviceId != expectedRecipientDeviceId ||
        validForMs is! int ||
        validForMs <= 0 ||
        validForMs > LanPairingCrypto.credentialTtlMillis ||
        elapsed.inMilliseconds > validForMs) {
      throw const FormatException(
        'Pairing response credential binding is invalid or expired',
      );
    }

    return _ValidatedPairingCredential(
      accessToken: accessToken,
      certFingerprint: fingerprint,
      status: status as String,
    );
  }

  /// 为定向协议测试校验配对凭据绑定。
  @visibleForTesting
  bool isPairingCredentialBindingValidForTesting(
    Map<String, dynamic> credential, {
    required String expectedNonce,
    required String expectedHandshakeId,
    required String expectedRequestHash,
    required String expectedIssuerDeviceId,
    required String expectedRecipientDeviceId,
    Duration elapsed = Duration.zero,
  }) {
    try {
      _validatePairingCredential(
        credential,
        expectedNonce: expectedNonce,
        expectedHandshakeId: expectedHandshakeId,
        expectedRequestHash: expectedRequestHash,
        expectedIssuerDeviceId: expectedIssuerDeviceId,
        expectedRecipientDeviceId: expectedRecipientDeviceId,
        elapsed: elapsed,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 发送 v1 握手请求，并校验配对 PIN 响应。
  Future<NetworkResult<LanHandshakeData>> sendHandshake(
    LanDevice device,
    String pin,
    String localAlias, {
    bool isInitiator = true,
  }) async {
    Object? lastError;
    NetworkSuccess<LanHandshakeData>? lastPendingResult;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final result = await _sendHandshakeAttempt(
          device,
          pin,
          localAlias,
          isInitiator: isInitiator,
        );
        if (result is NetworkFailure<LanHandshakeData>) {
          // 有效的 pending 响应已经证明远端 PIN 正确。
          // 若短确认重试恰好遇到 PIN 轮换，应保留该结果并等待对端，
          // 不要将其误判为 PIN 不匹配。
          return lastPendingResult ?? result;
        }
        final success = (result as NetworkSuccess<LanHandshakeData>);
        if (!success.data.pendingRemote) return success;

        // 两端可能几乎同时提交 PIN。此时双方服务端都可能在本地保存相互凭据前
        // 返回 pending。使用有界退避和新的 SPAKE2 会话重试，让服务端相互校验
        // 最终收敛，同时不降低配对后的授权强度。
        lastPendingResult = success;
        lastError = null;
      } catch (e) {
        lastError = lanNetworkError(
          e,
          operation: NetworkOperation.sendHandshake,
          peerId: device.id,
        );
      }

      if (attempt < 3) {
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }

    if (lastPendingResult != null) return lastPendingResult;
    if (lastError is NetworkError) {
      return NetworkFailure(lastError);
    }
    return NetworkFailure(
      NetworkError(
        code: NetworkErrorCode.ioError,
        message: 'LAN handshake failed.',
        operation: NetworkOperation.sendHandshake,
        peerId: device.id,
      ),
    );
  }

  /// 执行一次 v1 配对握手尝试。
  Future<NetworkResult<LanHandshakeData>> _sendHandshakeAttempt(
    LanDevice device,
    String pin,
    String localAlias, {
    required bool isInitiator,
  }) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'LAN pairing PIN format is invalid.',
          operation: NetworkOperation.sendHandshake,
          peerId: device.id,
        ),
      );
    }
    final url = Uri.parse(
      'https://${device.ip}:${device.port}/api/lan/handshake',
    );
    final nonce = LanPairingCrypto.randomToken();
    final localFingerprint =
        (await securityService.getLocalCertificateFingerprint(
          currentDeviceId,
        )).toLowerCase();
    final clientContext = LanPairingCrypto.clientContext(
      senderDeviceId: currentDeviceId,
      targetDeviceId: device.id,
      nonce: nonce,
      alias: localAlias,
      os: Platform.operatingSystem,
      port: activePort,
      isInitiator: isInitiator,
      senderCertFingerprint: localFingerprint,
    );
    final clientKeys = List<LanPairingEphemeralKeyPair>.generate(
      LanPairingCrypto.maxServerOffers,
      (slot) => LanPairingCrypto.generateClientKeyPair(
        pin: pin,
        clientContext: clientContext,
        slot: slot,
      ),
      growable: false,
    );
    final encodedClientPublicValues = clientKeys
        .map((keys) => base64.encode(keys.publicValue))
        .toList(growable: false);
    final stopwatch = Stopwatch()..start();

    final beginClient = await _createHttpClient(
      peerDeviceId: device.id,
      expectedFingerprint: device.certFingerprint,
      allowUntrusted: true,
    );
    late final _AcceptedPairingOffer acceptedOffer;
    try {
      final request = await beginClient
          .postUrl(url)
          .timeout(const Duration(seconds: 4));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'protocolVersion': LanPairingCrypto.protocolVersion,
          'phase': 'begin',
          'deviceId': currentDeviceId,
          'targetDeviceId': device.id,
          'alias': localAlias,
          'os': Platform.operatingSystem,
          'port': activePort,
          'isInitiator': isInitiator,
          'nonce': nonce,
          'certFingerprint': localFingerprint,
          'clientPublicValues': encodedClientPublicValues,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final json = await readBoundedJsonResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        throw lanHttpException(
          statusCode: response.statusCode,
          body: json,
          operation: NetworkOperation.sendHandshake,
          peerId: device.id,
          fallbackMessage: 'LAN pairing challenge was rejected.',
        );
      }
      if (json['protocolVersion'] != LanPairingCrypto.protocolVersion) {
        throw LanNetworkException(
          'LAN pairing challenge protocol is invalid.',
          code: NetworkErrorCode.invalidArgument,
          operation: NetworkOperation.sendHandshake,
          peerId: device.id,
          statusCode: response.statusCode,
        );
      }
      final serverFingerprint = json['certFingerprint'];
      final validForMs = json['validForMs'];
      final offers = json['offers'];
      if (serverFingerprint is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(serverFingerprint) ||
          validForMs is! int ||
          validForMs <= 0 ||
          validForMs > LanPairingCrypto.credentialTtlMillis ||
          stopwatch.elapsedMilliseconds > validForMs ||
          offers is! List<dynamic> ||
          offers.isEmpty ||
          offers.length > LanPairingCrypto.maxServerOffers) {
        throw const FormatException('Invalid LAN pairing challenge');
      }
      final normalizedFingerprint = serverFingerprint.toLowerCase();
      final advertisedFingerprint = device.certFingerprint?.toLowerCase();
      if (advertisedFingerprint != null &&
          advertisedFingerprint.isNotEmpty &&
          advertisedFingerprint != normalizedFingerprint) {
        throw const FormatException('LAN pairing certificate changed');
      }
      _AcceptedPairingOffer? selected;
      for (final rawOffer in offers) {
        if (rawOffer is! Map<String, dynamic>) continue;
        final candidate = await _acceptPairingOffer(
          rawOffer,
          clientKeys: clientKeys,
          clientContext: clientContext,
          serverFingerprint: normalizedFingerprint,
        );
        if (candidate != null) {
          selected = candidate;
          break;
        }
      }
      if (selected == null) {
        return NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.authenticationFailed,
            message: 'LAN pairing authentication failed.',
            operation: NetworkOperation.sendHandshake,
            peerId: device.id,
          ),
        );
      }
      acceptedOffer = selected;
    } finally {
      beginClient.close();
    }

    final confirmClient = await _createHttpClient(
      peerDeviceId: device.id,
      expectedFingerprint: acceptedOffer.certFingerprint,
    );
    try {
      final request = await confirmClient
          .postUrl(url)
          .timeout(const Duration(seconds: 4));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'protocolVersion': LanPairingCrypto.protocolVersion,
          'phase': 'confirm',
          'handshakeId': acceptedOffer.handshakeId,
          'deviceId': currentDeviceId,
          'targetDeviceId': device.id,
          'nonce': nonce,
          'clientProof': LanPairingCrypto.createClientProof(
            acceptedOffer.sessionSecrets,
          ),
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final json = await readBoundedJsonResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        throw lanHttpException(
          statusCode: response.statusCode,
          body: json,
          operation: NetworkOperation.sendHandshake,
          peerId: device.id,
          fallbackMessage: 'LAN pairing confirmation was rejected.',
        );
      }
      final encryptedCredential = json['credential'];
      if (encryptedCredential is! String || encryptedCredential.isEmpty) {
        throw const FormatException(
          'Pairing response omitted its encrypted credential',
        );
      }
      final associatedData = LanPairingCrypto.credentialAssociatedData(
        handshakeId: acceptedOffer.handshakeId,
        nonce: nonce,
        issuerDeviceId: device.id,
        recipientDeviceId: currentDeviceId,
      );
      final credential = await LanPairingCrypto.decryptCredential(
        encryptedCredential,
        acceptedOffer.sessionSecrets.sessionKey,
        associatedData: associatedData,
      );
      final requestHash = LanPairingCrypto.requestHash(clientContext);
      final validatedCredential = _validatePairingCredential(
        credential,
        expectedNonce: nonce,
        expectedHandshakeId: acceptedOffer.handshakeId,
        expectedRequestHash: requestHash,
        expectedIssuerDeviceId: device.id,
        expectedRecipientDeviceId: currentDeviceId,
        elapsed: stopwatch.elapsed,
      );
      if (validatedCredential.certFingerprint.toLowerCase() !=
          acceptedOffer.certFingerprint) {
        throw const FormatException('LAN pairing certificate changed');
      }
      await securityService.storeOutboundAccessToken(
        device.id,
        validatedCredential.accessToken,
      );
      await securityService.storePeerCertificateFingerprint(
        device.id,
        acceptedOffer.certFingerprint,
      );
      securityService.markFreshOutboundPairProof(
        deviceId: device.id,
        peerFingerprint: acceptedOffer.certFingerprint,
        localFingerprint: localFingerprint,
        accessToken: validatedCredential.accessToken,
      );
      return NetworkSuccess(
        LanHandshakeData(
          pendingRemote: validatedCredential.status == 'pending_remote',
        ),
      );
    } finally {
      confirmClient.close();
    }
  }

  /// 完成本地校验后接受远端配对邀请。
  /// 尝试解密并验证一个服务端配对 offer。
  Future<_AcceptedPairingOffer?> _acceptPairingOffer(
    Map<String, dynamic> offer, {
    required List<LanPairingEphemeralKeyPair> clientKeys,
    required String clientContext,
    required String serverFingerprint,
  }) async {
    final handshakeId = offer['handshakeId'];
    final slot = offer['slot'];
    final saltB64 = offer['salt'];
    final serverPublicValueB64 = offer['serverPublicValue'];
    final serverProof = offer['serverProof'];
    if (handshakeId is! String ||
        handshakeId.length < 16 ||
        handshakeId.length > 128 ||
        slot is! int ||
        slot < 0 ||
        slot >= clientKeys.length ||
        saltB64 is! String ||
        saltB64.length > 128 ||
        serverPublicValueB64 is! String ||
        serverPublicValueB64.length > 1024 ||
        serverProof is! String ||
        serverProof.isEmpty ||
        serverProof.length > 256) {
      return null;
    }
    try {
      final keys = clientKeys[slot];
      final salt = base64.decode(saltB64);
      if (salt.length != 32 || !listEquals(salt, keys.salt)) {
        return null;
      }
      final serverPublicValue = base64.decode(serverPublicValueB64);
      if (serverPublicValue.length != LanPairingCrypto.publicValueBytes ||
          !LanPairingCrypto.isValidPublicValueForTesting(serverPublicValue)) {
        return null;
      }
      final associatedData = LanPairingCrypto.sessionAssociatedData(
        clientContext: clientContext,
        handshakeId: handshakeId,
        slot: slot,
        salt: salt,
        clientPublicValue: keys.publicValue,
        serverPublicValue: serverPublicValue,
        serverCertFingerprint: serverFingerprint,
      );
      final sessionSecrets = LanPairingCrypto.deriveSessionSecrets(
        localKeyPair: keys,
        remotePublicValue: serverPublicValue,
        associatedData: associatedData,
      );
      if (!LanPairingCrypto.verifyServerProof(sessionSecrets, serverProof)) {
        return null;
      }
      return _AcceptedPairingOffer(
        handshakeId: handshakeId,
        sessionSecrets: sessionSecrets,
        certFingerprint: serverFingerprint,
      );
    } catch (_) {
      return null;
    }
  }

  /// 在已认证 LAN 通道上发送元数据消息。
  Future<NetworkResult<void>> sendMeta(
    LanDevice device,
    LanMessage message, {
    Uint8List? recipientPubKeyBytes,
  }) async {
    return _executeWithRetry(
      () async {
        final url = Uri.parse(
          'https://${device.ip}:${device.port}/api/lan/meta',
        );
        final client = await _createHttpClient(peerDeviceId: device.id);

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          final authorization = await addPairingAuthorization(
            request.headers,
            device.id,
          );
          if (authorization is NetworkFailure<void>) {
            return authorization;
          }
          final payload = <String, dynamic>{
            ...message.toJson(),
            'localPath': null,
            'sftpServerId': null,
            'sftpRemotePath': null,
          };
          final jsonBytes = utf8.encode(jsonEncode(payload));

          if (recipientPubKeyBytes != null) {
            // E2E：加密元数据载荷。
            final encrypted = await securityService.encryptE2EFor(
              Uint8List.fromList(jsonBytes),
              recipientPubKeyBytes,
            );
            request.headers.set('x-e2e-pubkey', '1');
            request.headers.contentType = ContentType.binary;
            request.headers.contentLength = encrypted.length;
            request.add(encrypted);
          } else {
            request.headers.contentType = ContentType.json;
            request.add(jsonBytes);
          }

          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          final json = await readBoundedJsonResponse(response);
          if (response.statusCode != HttpStatus.ok) {
            throw lanHttpException(
              statusCode: response.statusCode,
              body: json,
              operation: NetworkOperation.sendMeta,
              peerId: device.id,
              fallbackMessage: 'LAN metadata request was rejected.',
            );
          }
          if (json['id'] != message.id) {
            throw LanNetworkException(
              'LAN metadata response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendMeta,
              peerId: device.id,
              statusCode: response.statusCode,
            );
          }
          return const NetworkSuccess<void>(null);
        } finally {
          client.close();
        }
      },
      peerId: device.id,
      operation: NetworkOperation.sendMeta,
    );
  }

  /// 以 512KB 分块发送文件二进制流，并通过回调报告进度。
  /// [recipientPubKeyBytes] 非空时，整个文件会先缓冲，再作为单个 E2E 加密
  /// 载荷发送，而不是使用流式上传。
  Future<NetworkResult<void>> sendFileStream({
    required LanDevice device,
    required LanMessage message,
    required Stream<List<int>> fileStream,
    required int totalBytes,
    Uint8List? recipientPubKeyBytes,
    void Function(int bytesSent)? onProgress,
  }) async {
    if (totalBytes < 0 ||
        (recipientPubKeyBytes != null &&
            totalBytes > LanTransferProtocolGuard.maxEncryptedUploadBytes)) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'LAN file size is invalid.',
          operation: NetworkOperation.sendFile,
          peerId: device.id,
        ),
      );
    }
    return _executeWithRetry(
      () async {
        final url = Uri.parse(
          'https://${device.ip}:${device.port}/api/lan/upload',
        );
        final client = await _createHttpClient(peerDeviceId: device.id);

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          final authorization = await addPairingAuthorization(
            request.headers,
            device.id,
          );
          if (authorization is NetworkFailure<void>) {
            return authorization;
          }
          request.headers.set('x-message-id', message.id);
          request.headers.set(
            'x-file-name',
            Uri.encodeComponent(message.fileName ?? 'file.bin'),
          );

          if (recipientPubKeyBytes != null) {
            // E2E：先完整缓冲文件，再加密后发送。
            final rawBytes = BytesBuilder(copy: false);
            var bytesRead = 0;
            await for (final chunk in fileStream) {
              bytesRead += chunk.length;
              if (bytesRead > totalBytes ||
                  bytesRead >
                      LanTransferProtocolGuard.maxEncryptedUploadBytes) {
                throw LanNetworkException(
                  'Encrypted file exceeded its accepted size.',
                  code: NetworkErrorCode.invalidArgument,
                  operation: NetworkOperation.sendFile,
                  peerId: device.id,
                );
              }
              rawBytes.add(chunk);
            }
            if (bytesRead != totalBytes) {
              throw LanNetworkException(
                'File size changed before it could be uploaded.',
                code: NetworkErrorCode.invalidArgument,
                operation: NetworkOperation.sendFile,
                peerId: device.id,
              );
            }
            onProgress?.call(bytesRead);
            final encrypted = await securityService.encryptE2EFor(
              rawBytes.takeBytes(),
              recipientPubKeyBytes,
            );
            request.headers.set('x-e2e-pubkey', '1');
            request.headers.contentType = ContentType.binary;
            request.headers.contentLength = encrypted.length;
            request.add(encrypted);
          } else {
            // 普通流式上传。
            request.headers.contentLength = totalBytes;
            int bytesSent = 0;
            await for (final chunk in fileStream) {
              if (bytesSent + chunk.length > totalBytes) {
                throw LanNetworkException(
                  'File size changed before it could be uploaded.',
                  code: NetworkErrorCode.invalidArgument,
                  operation: NetworkOperation.sendFile,
                  peerId: device.id,
                );
              }
              request.add(chunk);
              bytesSent += chunk.length;
              onProgress?.call(bytesSent);
            }
            if (bytesSent != totalBytes) {
              throw LanNetworkException(
                'File size changed before it could be uploaded.',
                code: NetworkErrorCode.invalidArgument,
                operation: NetworkOperation.sendFile,
                peerId: device.id,
              );
            }
          }

          final uploadTimeout = Duration(
            seconds: (60 + (totalBytes / (1024 * 1024)).ceil()).clamp(
              60,
              4 * 60 * 60,
            ),
          );
          final response = await request.close().timeout(uploadTimeout);
          final json = await readBoundedJsonResponse(
            response,
            timeout: const Duration(seconds: 8),
          );
          if (response.statusCode != HttpStatus.ok) {
            throw lanHttpException(
              statusCode: response.statusCode,
              body: json,
              operation: NetworkOperation.sendFile,
              peerId: device.id,
              fallbackMessage: 'LAN file upload was rejected.',
            );
          }
          if (json['messageId'] != message.id) {
            throw LanNetworkException(
              'LAN file upload response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendFile,
              peerId: device.id,
              statusCode: response.statusCode,
            );
          }
          return const NetworkSuccess<void>(null);
        } finally {
          client.close();
        }
      },
      maxAttempts: 1,
      peerId: device.id,
      operation: NetworkOperation.sendFile,
    );
  }

  /// 为之前发送的消息发送撤回信号。
  Future<NetworkResult<void>> sendRecall(
    LanDevice device,
    String messageId,
  ) async {
    return _executeWithRetry(
      () async {
        final url = Uri.parse(
          'https://${device.ip}:${device.port}/api/lan/recall',
        );
        final client = await _createHttpClient(peerDeviceId: device.id);

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          final authorization = await addPairingAuthorization(
            request.headers,
            device.id,
          );
          if (authorization is NetworkFailure<void>) {
            return authorization;
          }
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode({'messageId': messageId}));

          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          final json = await readBoundedJsonResponse(
            response,
            timeout: const Duration(seconds: 8),
          );
          if (response.statusCode != HttpStatus.ok) {
            throw lanHttpException(
              statusCode: response.statusCode,
              body: json,
              operation: NetworkOperation.sendRecall,
              peerId: device.id,
              fallbackMessage: 'LAN recall request was rejected.',
            );
          }
          if (json['messageId'] != messageId) {
            throw LanNetworkException(
              'LAN recall response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendRecall,
              peerId: device.id,
              statusCode: response.statusCode,
            );
          }
          return const NetworkSuccess<void>(null);
        } finally {
          client.close();
        }
      },
      peerId: device.id,
      operation: NetworkOperation.sendRecall,
    );
  }

  /// 广播本机存在，并返回对端端点。
  Future<NetworkResult<LanPairingEndpoint>> sendAnnouncement(
    LanDevice targetDevice,
    String localAlias,
  ) async {
    return _executeWithRetry(
      () async {
        final url = Uri.parse(
          'https://${targetDevice.ip}:${targetDevice.port}/api/lan/announce',
        );
        final client = await _createHttpClient(peerDeviceId: targetDevice.id);

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode({
              'id': currentDeviceId,
              'alias': localAlias,
              'os': Platform.operatingSystem,
              'port': activePort,
            }),
          );

          final response = await request.close().timeout(
            const Duration(seconds: 4),
          );
          final json = await readBoundedJsonResponse(response);
          if (response.statusCode != HttpStatus.ok) {
            throw lanHttpException(
              statusCode: response.statusCode,
              body: json,
              operation: NetworkOperation.sendAnnouncement,
              peerId: targetDevice.id,
              fallbackMessage: 'LAN announcement was rejected.',
            );
          }
          final remoteDeviceId = json['deviceId'];
          final remotePort = json['port'];
          if (remoteDeviceId is! String ||
              remoteDeviceId.isEmpty ||
              remotePort is! num ||
              remotePort < 1 ||
              remotePort > 65535) {
            throw LanNetworkException(
              'LAN announcement response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendAnnouncement,
              peerId: targetDevice.id,
              statusCode: response.statusCode,
            );
          }
          return NetworkSuccess(
            LanPairingEndpoint(
              remoteDeviceId: remoteDeviceId,
              remotePort: remotePort.toInt(),
            ),
          );
        } finally {
          client.close();
        }
      },
      peerId: targetDevice.id,
      operation: NetworkOperation.sendAnnouncement,
    );
  }

  /// 邀请对端打开配对页面。PIN 握手仍是独立步骤，只有它可以建立信任。
  Future<NetworkResult<LanPairingEndpoint>> sendPairingInvite(
    LanDevice targetDevice,
    String localAlias, {
    required String sessionId,
    required DateTime expiresAt,
  }) async {
    final url = Uri.parse(
      'https://${targetDevice.ip}:${targetDevice.port}/api/lan/pairing_invite',
    );
    final client = await _createHttpClient(
      peerDeviceId: targetDevice.id,
      expectedFingerprint: targetDevice.certFingerprint,
      allowUntrusted: true,
    );
    try {
      final validForMs = expiresAt
          .difference(DateTime.now())
          .inMilliseconds
          .clamp(1, const Duration(minutes: 2).inMilliseconds);
      final request = await client
          .postUrl(url)
          .timeout(const Duration(seconds: 4));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'deviceId': currentDeviceId,
          'alias': localAlias,
          'os': Platform.operatingSystem,
          'port': activePort,
          'sessionId': sessionId,
          'validForMs': validForMs,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final json = await readBoundedJsonResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        throw lanHttpException(
          statusCode: response.statusCode,
          body: json,
          operation: NetworkOperation.sendPairingInvite,
          peerId: targetDevice.id,
          fallbackMessage: 'LAN pairing invitation was rejected.',
        );
      }
      final remoteDeviceId = json['deviceId'];
      final remotePort = json['port'];
      if (remoteDeviceId is! String ||
          remoteDeviceId.isEmpty ||
          remotePort is! num ||
          remotePort < 1 ||
          remotePort > 65535) {
        throw const FormatException('Invalid LAN pairing endpoint response.');
      }
      return NetworkSuccess(
        LanPairingEndpoint(
          remoteDeviceId: remoteDeviceId,
          remotePort: remotePort.toInt(),
        ),
      );
    } catch (e) {
      return NetworkFailure(
        lanNetworkError(
          e,
          operation: NetworkOperation.sendPairingInvite,
          peerId: targetDevice.id,
        ),
      );
    } finally {
      client.close();
    }
  }

  /// 使用指数退避重试暂时性失败，最多重试 3 次。
  Future<NetworkResult<T>> _executeWithRetry<T>(
    Future<NetworkResult<T>> Function() action, {
    int maxAttempts = 3,
    required NetworkOperation operation,
    String? peerId,
  }) async {
    NetworkFailure<T>? lastFailure;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final result = await action();
        if (result is NetworkSuccess<T>) return result;
        final failure = result as NetworkFailure<T>;
        lastFailure = failure;
        if (!failure.error.code.retryable || attempt == maxAttempts) {
          return failure;
        }
      } catch (e) {
        lastFailure = NetworkFailure(
          lanNetworkError(e, operation: operation, peerId: peerId),
        );
        if (attempt == maxAttempts || !lastFailure.error.code.retryable) {
          return lastFailure;
        }
      }
      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    return lastFailure ??
        NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'LAN operation failed.',
            operation: operation,
            peerId: peerId,
          ),
        );
  }
}
