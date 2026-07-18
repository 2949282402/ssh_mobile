import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lan_security_service.dart';

class LanHttpException implements Exception {
  final int statusCode;
  final String message;

  const LanHttpException(this.statusCode, this.message);
}

class LanPendingUpload {
  final String messageId;
  final String senderDeviceId;
  final String fileName;
  final int expectedBytes;
  final bool encrypted;
  final DateTime expiresAt;

  const LanPendingUpload({
    required this.messageId,
    required this.senderDeviceId,
    required this.fileName,
    required this.expectedBytes,
    required this.encrypted,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Validates bounded LAN control requests and authenticated transfer sessions.
class LanTransferProtocolGuard {
  static const int maxControlBodyBytes = 64 * 1024;
  static const int maxMetadataBodyBytes = 1024 * 1024;
  static const int maxEncryptedUploadBytes = 64 * 1024 * 1024;
  static const int maxAdvertisedFileBytes = 20 * 1024 * 1024 * 1024;
  static const int maxPendingUploadSessions = 64;
  static const int maxPendingPairingHandshakes = 64;
  static const int maxRememberedPairingNonces = 256;

  final String currentDeviceId;
  final LanSecurityService securityService;
  final Map<String, LanPendingUpload> _pendingUploads = {};
  final Map<String, DateTime> _lastInviteByAddress = {};
  final List<DateTime> _recentInvites = [];
  final Map<String, List<DateTime>> _pairingAttemptsByAddress = {};
  final List<DateTime> _recentPairingAttempts = [];
  final Map<String, DateTime> _pairingNonces = {};

  LanTransferProtocolGuard({
    required this.currentDeviceId,
    required this.securityService,
  });

  Future<Uint8List> readBytes(
    HttpRequest request, {
    required int maxBytes,
  }) async {
    final declaredLength = request.contentLength;
    if (declaredLength > maxBytes) {
      throw const LanHttpException(
        HttpStatus.requestEntityTooLarge,
        'Request body is too large.',
      );
    }

    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > maxBytes) {
        throw const LanHttpException(
          HttpStatus.requestEntityTooLarge,
          'Request body is too large.',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<Map<String, dynamic>> readJson(
    HttpRequest request, {
    int maxBytes = maxControlBodyBytes,
  }) async {
    final bytes = await readBytes(request, maxBytes: maxBytes);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object.');
      }
      return decoded;
    } on FormatException {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Malformed JSON request.',
      );
    }
  }

  Future<String> authorize(HttpRequest request) async {
    final senderDeviceId = request.headers.value('x-device-id')?.trim() ?? '';
    final authorization =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (senderDeviceId.isEmpty ||
        senderDeviceId.length > 128 ||
        senderDeviceId == currentDeviceId ||
        !authorization.startsWith('Bearer ')) {
      throw const LanHttpException(
        HttpStatus.unauthorized,
        'Pairing credentials are required.',
      );
    }
    final token = authorization.substring('Bearer '.length).trim();
    if (token.isEmpty || token.length > 256) {
      throw const LanHttpException(
        HttpStatus.unauthorized,
        'Pairing credentials are required.',
      );
    }
    final paired = await securityService.isDevicePaired(senderDeviceId);
    final tokenValid = await securityService.verifyInboundAccessToken(
      senderDeviceId,
      token,
    );
    if (!paired || !tokenValid) {
      throw const LanHttpException(
        HttpStatus.forbidden,
        'Pairing credentials are invalid or expired.',
      );
    }
    return senderDeviceId;
  }

  void checkPairingInviteRate(String remoteAddress) {
    final now = DateTime.now();
    _lastInviteByAddress.removeWhere(
      (_, lastSeen) => now.difference(lastSeen) > const Duration(minutes: 1),
    );
    _recentInvites.removeWhere(
      (createdAt) => now.difference(createdAt) > const Duration(minutes: 1),
    );
    final lastInvite = _lastInviteByAddress[remoteAddress];
    if ((lastInvite != null &&
            now.difference(lastInvite) < const Duration(seconds: 2)) ||
        _recentInvites.length >= 12) {
      throw const LanHttpException(
        HttpStatus.tooManyRequests,
        'Too many pairing invitations.',
      );
    }
    _lastInviteByAddress[remoteAddress] = now;
    _recentInvites.add(now);
  }

  void checkPairingAttemptRate(String remoteAddress) {
    final now = DateTime.now();
    _recentPairingAttempts.removeWhere(
      (createdAt) => now.difference(createdAt) > const Duration(minutes: 1),
    );
    _pairingAttemptsByAddress.removeWhere((_, attempts) {
      attempts.removeWhere(
        (createdAt) => now.difference(createdAt) > const Duration(minutes: 1),
      );
      return attempts.isEmpty;
    });
    final attempts = _pairingAttemptsByAddress.putIfAbsent(
      remoteAddress,
      () => <DateTime>[],
    );
    if (attempts.length >= 8 || _recentPairingAttempts.length >= 48) {
      throw const LanHttpException(
        HttpStatus.tooManyRequests,
        'Too many LAN pairing attempts.',
      );
    }
    attempts.add(now);
    _recentPairingAttempts.add(now);
  }

  void checkPairingNonce(String deviceId, String nonce) {
    final now = DateTime.now();
    _pairingNonces.removeWhere(
      (_, createdAt) => now.difference(createdAt) > const Duration(minutes: 2),
    );
    final key = '$deviceId\u0000$nonce';
    if (_pairingNonces.containsKey(key)) {
      throw const LanHttpException(
        HttpStatus.conflict,
        'Pairing request has already been used.',
      );
    }
    if (_pairingNonces.length >= maxRememberedPairingNonces) {
      throw const LanHttpException(
        HttpStatus.tooManyRequests,
        'Too many pairing requests are in progress.',
      );
    }
    _pairingNonces[key] = now;
  }

  void registerPendingUpload(LanPendingUpload upload) {
    _prunePendingUploads();
    if (upload.messageId.isEmpty || upload.messageId.length > 128) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid upload message ID.',
      );
    }
    if (upload.expectedBytes < 0 ||
        upload.expectedBytes > maxAdvertisedFileBytes ||
        (upload.encrypted && upload.expectedBytes > maxEncryptedUploadBytes)) {
      throw const LanHttpException(
        HttpStatus.requestEntityTooLarge,
        'Advertised file is too large.',
      );
    }
    final key = _uploadKey(upload.senderDeviceId, upload.messageId);
    if (!_pendingUploads.containsKey(key) &&
        _pendingUploads.length >= maxPendingUploadSessions) {
      throw const LanHttpException(
        HttpStatus.tooManyRequests,
        'Too many uploads are pending.',
      );
    }
    _pendingUploads[key] = upload;
  }

  LanPendingUpload requirePendingUpload({
    required String messageId,
    required String senderDeviceId,
    required String fileName,
    required bool encrypted,
  }) {
    _prunePendingUploads();
    final pending = _pendingUploads[_uploadKey(senderDeviceId, messageId)];
    if (pending == null ||
        pending.isExpired ||
        pending.senderDeviceId != senderDeviceId ||
        pending.fileName != fileName ||
        pending.encrypted != encrypted) {
      throw const LanHttpException(
        HttpStatus.forbidden,
        'No matching accepted upload was found.',
      );
    }
    return pending;
  }

  void completePendingUpload(String senderDeviceId, String messageId) {
    _pendingUploads.remove(_uploadKey(senderDeviceId, messageId));
  }

  String _uploadKey(String senderDeviceId, String messageId) =>
      '$senderDeviceId\u0000$messageId';

  void _prunePendingUploads() {
    _pendingUploads.removeWhere((_, upload) => upload.isExpired);
  }
}
