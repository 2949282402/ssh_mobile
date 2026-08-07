// v1 LAN HTTP 边界校验、配对限流与待处理上传会话管理。
// 本文件只负责验证不可信请求和维护内存状态；公开网络结果由上层服务统一转换。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lan_security_service.dart';

/// LAN HTTP 边界异常，供服务端将安全诊断转换为统一 JSON 响应。
class LanHttpException implements Exception {
  /// 使用 HTTP 状态码和安全诊断创建异常。
  const LanHttpException(this.statusCode, this.message);

  final int statusCode;
  final String message;
}

/// 记录一个已经通过元数据审批的上传会话。
class LanPendingUpload {
  final String messageId;
  final String senderDeviceId;
  final String fileName;
  final int expectedBytes;
  final bool encrypted;
  final DateTime expiresAt;

  /// 创建待处理上传记录。
  const LanPendingUpload({
    required this.messageId,
    required this.senderDeviceId,
    required this.fileName,
    required this.expectedBytes,
    required this.encrypted,
    required this.expiresAt,
  });

  /// 返回上传会话是否已经过期。
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// 校验有界 LAN 控制请求，并管理已认证的传输会话。
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

  /// 创建 LAN 协议校验器。
  LanTransferProtocolGuard({
    required this.currentDeviceId,
    required this.securityService,
  });

  /// 读取请求体，并在超过 [maxBytes] 时拒绝请求。
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

  /// 读取并解析有界 JSON 请求体。
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

  /// 校验配对凭据，并返回发送方设备标识。
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

  /// 校验来自指定地址的配对邀请速率。
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

  /// 校验来自指定地址的配对尝试速率。
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

  /// 校验配对 nonce 只被使用一次，并记录本次使用。
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

  /// 注册一个等待上传的元数据会话。
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

  /// 查找并校验与上传请求完全匹配的待处理会话。
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

  /// 完成后移除一个待处理上传会话。
  void completePendingUpload(String senderDeviceId, String messageId) {
    _pendingUploads.remove(_uploadKey(senderDeviceId, messageId));
  }

  /// 生成发送方与消息标识组合的内存 key。
  String _uploadKey(String senderDeviceId, String messageId) =>
      '$senderDeviceId\u0000$messageId';

  /// 清理已经过期的待处理上传会话。
  void _prunePendingUploads() {
    _pendingUploads.removeWhere((_, upload) => upload.isExpired);
  }
}
