part of 'lan_transfer_service.dart';

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
  Future<HttpClient> createHttpClientForPeer(String peerDeviceId) {
    return _createHttpClient(peerDeviceId: peerDeviceId);
  }

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

  /// Adds the per-pair credential required by all post-pair LAN APIs.
  Future<bool> addPairingAuthorization(
    HttpHeaders headers,
    String peerDeviceId,
  ) async {
    final token = await securityService.getOutboundAccessToken(peerDeviceId);
    if (token == null || token.isEmpty) return false;
    headers.set('x-device-id', currentDeviceId);
    headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    return true;
  }

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

  /// Send handshake (PIN validation) request to peer
  Future<HandshakeResult> sendHandshake(
    LanDevice device,
    String pin,
    String localAlias, {
    bool isInitiator = true,
  }) async {
    Object? lastError;
    HandshakeResult? lastPendingResult;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final result = await _sendHandshakeAttempt(
          device,
          pin,
          localAlias,
          isInitiator: isInitiator,
        );
        if (!result.success) {
          // A valid pending response has already proved the remote PIN. If the
          // short confirmation retry races a PIN rotation, retain that result
          // and wait for the peer instead of turning it into a mismatch.
          return lastPendingResult ?? result;
        }
        if (!result.pendingRemote) return result;

        // Both users can submit at almost exactly the same time. In that case
        // each server may answer pending before its local client persists the
        // reciprocal credential. Retry with a fresh SPAKE2 session after a
        // bounded backoff so the existing server-side reciprocal check can
        // converge without weakening post-pair authorization.
        lastPendingResult = result;
        lastError = null;
      } catch (e) {
        debugPrint(
          '[LanTransferService] Handshake attempt $attempt failed: $e',
        );
        lastError = e;
      }

      if (attempt < 3) {
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }

    if (lastPendingResult != null) return lastPendingResult;
    if (lastError != null) {
      if (lastError is Exception) {
        throw LanNetworkException('Network error during handshake: $lastError');
      } else {
        throw LanNetworkException(lastError.toString());
      }
    }
    return HandshakeResult(success: false);
  }

  Future<HandshakeResult> _sendHandshakeAttempt(
    LanDevice device,
    String pin,
    String localAlias, {
    required bool isInitiator,
  }) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      return HandshakeResult(success: false);
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
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        debugPrint('[LanTransferService] Handshake rejected: PIN mismatch');
        return HandshakeResult(success: false);
      }
      if (response.statusCode != HttpStatus.ok ||
          json['success'] != true ||
          json['protocolVersion'] != LanPairingCrypto.protocolVersion) {
        throw LanNetworkException('HTTP status ${response.statusCode}');
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
      if (selected == null) return HandshakeResult(success: false);
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
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        return HandshakeResult(success: false);
      }
      if (response.statusCode != HttpStatus.ok || json['success'] != true) {
        throw LanNetworkException('HTTP status ${response.statusCode}');
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
      return HandshakeResult(
        success: true,
        pendingRemote: validatedCredential.status == 'pending_remote',
      );
    } finally {
      confirmClient.close();
    }
  }

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

  /// Send metadata (text/clipboard or file transfer prompt) to peer
  Future<bool> sendMeta(
    LanDevice device,
    LanMessage message, {
    Uint8List? recipientPubKeyBytes,
  }) async {
    return _executeWithRetry(() async {
      final url = Uri.parse('https://${device.ip}:${device.port}/api/lan/meta');
      final client = await _createHttpClient(peerDeviceId: device.id);

      try {
        final request = await client
            .postUrl(url)
            .timeout(const Duration(seconds: 4));
        if (!await addPairingAuthorization(request.headers, device.id)) {
          return false;
        }
        final payload = <String, dynamic>{
          ...message.toJson(),
          'localPath': null,
          'sftpServerId': null,
          'sftpRemotePath': null,
        };
        final jsonBytes = utf8.encode(jsonEncode(payload));

        if (recipientPubKeyBytes != null) {
          // E2E: encrypt meta payload
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
        return response.statusCode == HttpStatus.ok &&
            (json['accepted'] == true);
      } finally {
        client.close();
      }
    });
  }

  /// Send file binary stream in 512KB chunks with progress callbacks.
  /// When [recipientPubKeyBytes] is non-null, the entire file is buffered
  /// and sent as a single E2E-encrypted blob (not a streaming upload).
  Future<bool> sendFileStream({
    required LanDevice device,
    required LanMessage message,
    required Stream<List<int>> fileStream,
    required int totalBytes,
    Uint8List? recipientPubKeyBytes,
    Function(int bytesSent)? onProgress,
  }) async {
    if (totalBytes < 0 ||
        (recipientPubKeyBytes != null &&
            totalBytes > LanTransferProtocolGuard.maxEncryptedUploadBytes)) {
      return false;
    }
    return _executeWithRetry(() async {
      final url = Uri.parse(
        'https://${device.ip}:${device.port}/api/lan/upload',
      );
      final client = await _createHttpClient(peerDeviceId: device.id);

      try {
        final request = await client
            .postUrl(url)
            .timeout(const Duration(seconds: 4));
        if (!await addPairingAuthorization(request.headers, device.id)) {
          return false;
        }
        request.headers.set('x-message-id', message.id);
        request.headers.set(
          'x-file-name',
          Uri.encodeComponent(message.fileName ?? 'file.bin'),
        );

        if (recipientPubKeyBytes != null) {
          // E2E: buffer entire file then encrypt before sending
          final rawBytes = BytesBuilder(copy: false);
          var bytesRead = 0;
          await for (final chunk in fileStream) {
            bytesRead += chunk.length;
            if (bytesRead > totalBytes ||
                bytesRead > LanTransferProtocolGuard.maxEncryptedUploadBytes) {
              throw LanNetworkException(
                'Encrypted file exceeded its accepted size.',
              );
            }
            rawBytes.add(chunk);
          }
          if (bytesRead != totalBytes) {
            throw LanNetworkException(
              'File size changed before it could be uploaded.',
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
          // Plain streaming upload
          request.headers.contentLength = totalBytes;
          int bytesSent = 0;
          await for (final chunk in fileStream) {
            if (bytesSent + chunk.length > totalBytes) {
              throw LanNetworkException(
                'File size changed before it could be uploaded.',
              );
            }
            request.add(chunk);
            bytesSent += chunk.length;
            onProgress?.call(bytesSent);
          }
          if (bytesSent != totalBytes) {
            throw LanNetworkException(
              'File size changed before it could be uploaded.',
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
        await response.drain<void>().timeout(const Duration(seconds: 8));
        return response.statusCode == HttpStatus.ok;
      } finally {
        client.close();
      }
    }, maxAttempts: 1);
  }

  /// Send RECALL signal to target device
  Future<bool> sendRecall(LanDevice device, String messageId) async {
    return _executeWithRetry(() async {
      final url = Uri.parse(
        'https://${device.ip}:${device.port}/api/lan/recall',
      );
      final client = await _createHttpClient(peerDeviceId: device.id);

      try {
        final request = await client
            .postUrl(url)
            .timeout(const Duration(seconds: 4));
        if (!await addPairingAuthorization(request.headers, device.id)) {
          return false;
        }
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'messageId': messageId}));

        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        await response.drain<void>().timeout(const Duration(seconds: 8));
        return response.statusCode == HttpStatus.ok;
      } finally {
        client.close();
      }
    });
  }

  /// Send an announcement of local presence to a target device
  Future<PairingInviteResult> sendAnnouncement(
    LanDevice targetDevice,
    String localAlias,
  ) async {
    PairingInviteResult result = const PairingInviteResult(success: false);
    final success = await _executeWithRetry(() async {
      final url = Uri.parse(
        'https://${targetDevice.ip}:${targetDevice.port}/api/lan/announce',
      );
      final client = await _createHttpClient();

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
        final accepted =
            response.statusCode == HttpStatus.ok && json['success'] == true;
        if (accepted) {
          result = PairingInviteResult(
            success: true,
            remoteDeviceId: json['deviceId'] as String?,
            remotePort: (json['port'] as num?)?.toInt(),
          );
        }
        return accepted;
      } finally {
        client.close();
      }
    });
    return success ? result : const PairingInviteResult(success: false);
  }

  /// Invite a peer to open its pairing page. The PIN handshake remains a
  /// separate step and is the only operation that establishes trust.
  Future<PairingInviteResult> sendPairingInvite(
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
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(const Duration(seconds: 4));
        return const PairingInviteResult(success: false);
      }
      final json = await readBoundedJsonResponse(response);
      return PairingInviteResult(
        success: json['accepted'] == true,
        remoteDeviceId: json['deviceId'] as String?,
        remotePort: (json['port'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('[LanTransferService] Pairing invite failed: $e');
      return const PairingInviteResult(success: false);
    } finally {
      client.close();
    }
  }

  /// Retries transient failures 3 times with exponential backoff
  Future<bool> _executeWithRetry(
    Future<bool> Function() action, {
    int maxAttempts = 3,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final success = await action();
        if (success) return true;
      } catch (e) {
        debugPrint('[LanTransferService] Attempt $attempt failed: $e');
        if (attempt == maxAttempts) return false;
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    return false;
  }
}
