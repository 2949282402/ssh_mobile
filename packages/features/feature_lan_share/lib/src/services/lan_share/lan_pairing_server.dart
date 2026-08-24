// 从传输服务拆出的 v1 LAN 配对 HTTP 端点处理逻辑。

part of 'lan_transfer_service.dart';

/// 保存一个 v1 配对挑战的服务端状态。
class _PendingPairingHandshake {
  final String handshakeId;
  final String senderDeviceId;
  final String nonce;
  final String alias;
  final String os;
  final int port;
  final bool isInitiator;
  final String senderCertFingerprint;
  final String serverCertFingerprint;
  final String clientContext;
  final LanPairingSessionSecrets sessionSecrets;
  final String remoteAddress;
  final DateTime expiresAt;

  /// 创建待处理配对挑战。
  const _PendingPairingHandshake({
    required this.handshakeId,
    required this.senderDeviceId,
    required this.nonce,
    required this.alias,
    required this.os,
    required this.port,
    required this.isInitiator,
    required this.senderCertFingerprint,
    required this.serverCertFingerprint,
    required this.clientContext,
    required this.sessionSecrets,
    required this.remoteAddress,
    required this.expiresAt,
  });

  /// 配对挑战是否已过期。
  bool get isExpired => !DateTime.now().isBefore(expiresAt);
}

extension _LanPairingServerOperations on LanTransferService {
  /// 将 v1 配对请求路由到 begin 或 confirm 阶段。
  Future<void> _handleSecureHandshakeRequest(HttpRequest request) async {
    final json = await _protocolGuard.readJson(request);
    if (json['protocolVersion'] != LanPairingCrypto.protocolVersion) {
      throw const LanHttpException(
        426,
        'A secure LAN pairing protocol upgrade is required.',
      );
    }
    final phase = json['phase'];
    if (phase == 'begin') {
      await _handleSecureHandshakeBegin(request, json);
      return;
    }
    if (phase == 'confirm') {
      await _handleSecureHandshakeConfirm(request, json);
      return;
    }
    throw const LanHttpException(
      HttpStatus.badRequest,
      'Invalid LAN pairing phase.',
    );
  }

  /// 校验配对 begin 请求并返回服务端挑战。
  Future<void> _handleSecureHandshakeBegin(
    HttpRequest request,
    Map<String, dynamic> json,
  ) async {
    final senderDeviceId = _trimmedPairingField(json, 'deviceId');
    final targetDeviceId = _trimmedPairingField(json, 'targetDeviceId');
    final alias = _trimmedPairingField(json, 'alias');
    final os = _trimmedPairingField(json, 'os');
    final nonce = _trimmedPairingField(json, 'nonce');
    final senderFingerprint = _trimmedPairingField(
      json,
      'certFingerprint',
    ).toLowerCase();
    final encodedClientPublicValues = json['clientPublicValues'];
    final port =
        (json['port'] as num?)?.toInt() ?? LanTransferService.defaultHttpPort;
    final isInitiator = json['isInitiator'] is bool
        ? json['isInitiator'] as bool
        : true;
    if (encodedClientPublicValues is! List<dynamic> ||
        encodedClientPublicValues.length != LanPairingCrypto.maxServerOffers) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN pairing public key.',
      );
    }
    final clientPublicValues = <Uint8List>[];
    try {
      for (final encoded in encodedClientPublicValues) {
        if (encoded is! String || encoded.length > 1024) {
          throw const FormatException();
        }
        final value = base64.decode(encoded);
        if (value.length != LanPairingCrypto.publicValueBytes ||
            !LanPairingCrypto.isValidPublicValueForTesting(value)) {
          throw const FormatException();
        }
        clientPublicValues.add(value);
      }
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN pairing public key.',
      );
    }
    if (senderDeviceId.isEmpty ||
        senderDeviceId == currentDeviceId ||
        senderDeviceId.length > 128 ||
        targetDeviceId != currentDeviceId ||
        alias.isEmpty ||
        alias.length > 128 ||
        os.isEmpty ||
        os.length > 64 ||
        port < 1 ||
        port > 65535 ||
        nonce.length < 16 ||
        nonce.length > 128 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(senderFingerprint)) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN pairing request.',
      );
    }

    final remoteAddress = _pairingRemoteAddress(request);
    _protocolGuard.checkPairingAttemptRate(remoteAddress);
    _prunePendingPairingHandshakes();
    if (_pendingPairingHandshakes.values.any(
      (pending) =>
          pending.senderDeviceId == senderDeviceId && pending.nonce == nonce,
    )) {
      throw const LanHttpException(
        HttpStatus.conflict,
        'LAN pairing request is already pending.',
      );
    }
    if (_pendingPairingHandshakes.length >=
        LanTransferProtocolGuard.maxPendingPairingHandshakes) {
      throw const LanHttpException(
        HttpStatus.tooManyRequests,
        'Too many LAN pairing requests are pending.',
      );
    }

    final pins = securityService.validPairingPinsForHandshake();
    if (pins.isEmpty) {
      throw const LanHttpException(
        HttpStatus.unauthorized,
        'No active LAN pairing code is available.',
      );
    }
    final serverFingerprint =
        (await securityService.getLocalCertificateFingerprint(
          currentDeviceId,
        )).toLowerCase();
    final clientContext = LanPairingCrypto.clientContext(
      senderDeviceId: senderDeviceId,
      targetDeviceId: targetDeviceId,
      nonce: nonce,
      alias: alias,
      os: os,
      port: port,
      isInitiator: isInitiator,
      senderCertFingerprint: senderFingerprint,
    );
    final offers = <Map<String, dynamic>>[];
    final offeredPins = pins.take(LanPairingCrypto.maxServerOffers).toList();
    for (var slot = 0; slot < offeredPins.length; slot++) {
      final pin = offeredPins[slot];
      try {
        final clientPublicValue = clientPublicValues[slot];
        final serverKeys = LanPairingCrypto.generateServerKeyPair(
          pin: pin,
          clientContext: clientContext,
          slot: slot,
          clientPublicValue: clientPublicValue,
        );
        final handshakeId = LanPairingCrypto.randomToken(byteLength: 18);
        final associatedData = LanPairingCrypto.sessionAssociatedData(
          clientContext: clientContext,
          handshakeId: handshakeId,
          slot: slot,
          salt: serverKeys.salt,
          clientPublicValue: clientPublicValue,
          serverPublicValue: serverKeys.publicValue,
          serverCertFingerprint: serverFingerprint,
        );
        final sessionSecrets = LanPairingCrypto.deriveSessionSecrets(
          localKeyPair: serverKeys,
          remotePublicValue: clientPublicValue,
          associatedData: associatedData,
        );
        _pendingPairingHandshakes[handshakeId] = _PendingPairingHandshake(
          handshakeId: handshakeId,
          senderDeviceId: senderDeviceId,
          nonce: nonce,
          alias: alias,
          os: os,
          port: port,
          isInitiator: isInitiator,
          senderCertFingerprint: senderFingerprint,
          serverCertFingerprint: serverFingerprint,
          clientContext: clientContext,
          sessionSecrets: sessionSecrets,
          remoteAddress: remoteAddress,
          expiresAt: DateTime.now().add(
            const Duration(milliseconds: LanPairingCrypto.credentialTtlMillis),
          ),
        );
        offers.add({
          'handshakeId': handshakeId,
          'slot': slot,
          'salt': base64.encode(serverKeys.salt),
          'serverPublicValue': base64.encode(serverKeys.publicValue),
          'serverProof': LanPairingCrypto.createServerProof(sessionSecrets),
        });
      } catch (_) {
        // 无效候选值必须与 PIN 不匹配保持相同表现，
        // 不得暴露使用了哪一个轮换 PIN 槽位。
      }
    }
    if (offers.isEmpty) {
      throw const LanHttpException(
        HttpStatus.unauthorized,
        'LAN pairing authentication failed.',
      );
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'protocolVersion': LanPairingCrypto.protocolVersion,
        'status': 'challenge',
        'certFingerprint': serverFingerprint,
        'validForMs': LanPairingCrypto.credentialTtlMillis,
        'offers': offers,
      }),
    );
    await request.response.close();
  }

  /// 校验配对证明并返回加密凭据。
  Future<void> _handleSecureHandshakeConfirm(
    HttpRequest request,
    Map<String, dynamic> json,
  ) async {
    final handshakeId = _trimmedPairingField(json, 'handshakeId');
    final senderDeviceId = _trimmedPairingField(json, 'deviceId');
    final targetDeviceId = _trimmedPairingField(json, 'targetDeviceId');
    final nonce = _trimmedPairingField(json, 'nonce');
    final clientProof = _trimmedPairingField(json, 'clientProof');
    if (handshakeId.length < 16 ||
        handshakeId.length > 128 ||
        senderDeviceId.isEmpty ||
        senderDeviceId.length > 128 ||
        targetDeviceId != currentDeviceId ||
        nonce.length < 16 ||
        nonce.length > 128 ||
        clientProof.isEmpty ||
        clientProof.length > 256) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN pairing confirmation.',
      );
    }

    _prunePendingPairingHandshakes();
    final pending = _pendingPairingHandshakes[handshakeId];
    final remoteAddress = _pairingRemoteAddress(request);
    if (pending == null ||
        pending.isExpired ||
        pending.senderDeviceId != senderDeviceId ||
        pending.nonce != nonce ||
        pending.remoteAddress != remoteAddress) {
      throw const LanHttpException(
        HttpStatus.unauthorized,
        'LAN pairing confirmation is invalid or expired.',
      );
    }
    _pendingPairingHandshakes.remove(handshakeId);
    if (!LanPairingCrypto.verifyClientProof(
      pending.sessionSecrets,
      clientProof,
    )) {
      throw const LanHttpException(
        HttpStatus.unauthorized,
        'LAN pairing authentication failed.',
      );
    }

    _protocolGuard.checkPairingNonce(senderDeviceId, nonce);
    try {
      await securityService.storePeerCertificateFingerprint(
        senderDeviceId,
        pending.senderCertFingerprint,
      );
    } on StateError {
      throw const LanHttpException(
        HttpStatus.conflict,
        'The device certificate changed. Unpair it before pairing again.',
      );
    }
    final accessToken = await securityService.issueInboundAccessToken(
      senderDeviceId,
    );
    final device = LanDevice(
      id: senderDeviceId,
      alias: pending.alias,
      ip: remoteAddress,
      port: pending.port,
      deviceType: _guessDeviceType(pending.os),
      osName: pending.os,
      certFingerprint: pending.senderCertFingerprint,
      lastSeen: DateTime.now(),
      isTrusted: true,
    );

    final reciprocalReady =
        await securityService.hasCompleteOutboundPairCredential(
          senderDeviceId,
        ) &&
        await securityService.consumeFreshOutboundPinProof(
          deviceId: senderDeviceId,
          peerFingerprint: pending.senderCertFingerprint,
          localFingerprint: pending.serverCertFingerprint,
        );
    final String status;
    if (!reciprocalReady) {
      status = 'pending_remote';
      _emit(_handshakePendingController, device);
    } else {
      status = 'paired';
      await securityService.confirmDevicePairing(senderDeviceId);
      _emit(_handshakeSuccessController, device);
    }

    final requestHash = LanPairingCrypto.requestHash(pending.clientContext);
    final associatedData = LanPairingCrypto.credentialAssociatedData(
      handshakeId: handshakeId,
      nonce: nonce,
      issuerDeviceId: currentDeviceId,
      recipientDeviceId: senderDeviceId,
    );
    final encryptedCredential = await LanPairingCrypto.encryptCredential(
      {
        'protocolVersion': LanPairingCrypto.protocolVersion,
        'accessToken': accessToken,
        'status': status,
        'certFingerprint': pending.serverCertFingerprint,
        'requestNonce': nonce,
        'handshakeId': handshakeId,
        'requestHash': requestHash,
        'issuerDeviceId': currentDeviceId,
        'recipientDeviceId': senderDeviceId,
        'validForMs': LanPairingCrypto.credentialTtlMillis,
      },
      pending.sessionSecrets.sessionKey,
      associatedData: associatedData,
    );

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'protocolVersion': LanPairingCrypto.protocolVersion,
        'status': status,
        'credential': encryptedCredential,
      }),
    );
    await request.response.close();
  }

  /// 从配对 JSON 读取并清理一个字符串字段。
  String _trimmedPairingField(Map<String, dynamic> json, String key) {
    final value = json[key];
    return value is String ? value.trim() : '';
  }

  /// 返回用于绑定配对发送方的规范化远端地址。
  String _pairingRemoteAddress(HttpRequest request) {
    var address = request.connectionInfo?.remoteAddress.address ?? '';
    if (address.startsWith('::ffff:')) address = address.substring(7);
    if (address.isEmpty) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'LAN pairing request has no source address.',
      );
    }
    return address;
  }

  /// 从内存中移除过期配对挑战。
  void _prunePendingPairingHandshakes() {
    _pendingPairingHandshakes.removeWhere((_, pending) => pending.isExpired);
  }
}
