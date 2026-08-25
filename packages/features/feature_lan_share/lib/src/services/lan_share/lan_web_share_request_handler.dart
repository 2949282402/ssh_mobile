// V2 WebShare request boundary and bounded upload handling.
//
// This library intentionally depends only on dart:io and the network
// contracts.  The Flutter services adapt their crypto, storage, and transfer
// callbacks at the production route boundary; a plain Dart process can
// therefore exercise the same handler and a real TLS listener.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';

import 'lan_network_models.dart';

/// Limits shared by the WebShare route and its browser client.
final class LanWebShareLimits {
  const LanWebShareLimits._();

  static const int maxControlBodyBytes = 64 * 1024;
  static const int maxRejectedBodyDrainBytes = maxControlBodyBytes;
  static const int maxEncryptedUploadBytes = 64 * 1024 * 1024;
  static const int maxAdvertisedFileBytes = 20 * 1024 * 1024 * 1024;
  static const Duration requestBodyIdleTimeout = Duration(seconds: 30);
  static const Duration rejectedBodyDrainTimeout = Duration(seconds: 1);
}

/// Status emitted by the WebShare route for an incoming browser file.
enum LanWebShareMessageStatus { pending, completed, failed }

/// Pure message DTO passed from the WebShare route to the transfer adapter.
final class LanWebShareMessage {
  const LanWebShareMessage({
    required this.id,
    required this.senderId,
    required this.senderAlias,
    required this.receiverId,
    required this.fileName,
    required this.fileSize,
    required this.bytesTransferred,
    required this.status,
    required this.createdAt,
    this.localPath,
  });

  final String id;
  final String senderId;
  final String senderAlias;
  final String receiverId;
  final String fileName;
  final int fileSize;
  final int bytesTransferred;
  final LanWebShareMessageStatus status;
  final DateTime createdAt;
  final String? localPath;
}

typedef LanWebShareDecryptPayload =
    Future<Uint8List> Function(Uint8List encrypted);
typedef LanWebShareHasSufficientSpace = Future<bool> Function(int fileSize);
typedef LanWebShareCreateTargetFile = Future<File> Function(String fileName);
typedef LanWebShareDeleteFile = Future<void> Function(String path);
typedef LanWebShareMessageCallback = void Function(LanWebShareMessage message);

/// Tracks a WebShare upload accepted by the metadata endpoint.
class _PendingWebUpload {
  final String messageId;
  final String fileName;
  final int expectedBytes;
  final bool encrypted;
  final DateTime expiresAt;

  const _PendingWebUpload({
    required this.messageId,
    required this.fileName,
    required this.expectedBytes,
    required this.encrypted,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// A normalized, endpoint-specific WebShare HTTP failure.
class LanWebShareHttpException implements Exception {
  final int statusCode;
  final String message;

  const LanWebShareHttpException(this.statusCode, this.message);

  @override
  String toString() => 'LanWebShareHttpException($statusCode, $message)';
}

/// Reusable WebShare request boundary used by HTTPS listeners and tests.
///
/// [isActive] is checked before every request and again after asynchronous
/// body/storage work. The handler owns upload reservations so a request cannot
/// bypass duplicate or capacity limits by racing another request.
final class LanWebShareRequestHandler {
  static const Duration pendingUploadTtl = Duration(minutes: 5);
  static const int maxPendingUploads = 32;
  static const int e2eEnvelopeOverheadBytes = 60;
  static const String webShareTokenHeader = 'x-web-share-token';

  final String currentDeviceId;
  final String webShareToken;
  final LanWebShareDecryptPayload decryptPayload;
  final LanWebShareHasSufficientSpace hasSufficientSpace;
  final LanWebShareCreateTargetFile createTargetFile;
  final LanWebShareDeleteFile deleteFile;
  final LanWebShareMessageCallback onIncomingMessage;
  final LanWebShareMessageCallback onMessageProgress;
  final bool Function() isActive;
  final String Function() buildHtml;
  final void Function(String message) logger;

  final Map<String, _PendingWebUpload> _pendingUploads = {};
  final Map<String, _PendingWebUpload> _activeUploads = {};
  final Expando<bool> _bodyReadStarted = Expando<bool>();
  final Expando<bool> _bodyFullyConsumed = Expando<bool>();

  LanWebShareRequestHandler({
    required this.currentDeviceId,
    required this.webShareToken,
    required this.decryptPayload,
    required this.hasSufficientSpace,
    required this.createTargetFile,
    required this.deleteFile,
    required this.onIncomingMessage,
    required this.onMessageProgress,
    required this.isActive,
    required this.buildHtml,
    this.logger = _ignoreLog,
  });

  static void _ignoreLog(String message) {}

  /// Release upload leases after the listener has stopped accepting work.
  Future<void> close() async {
    _pendingUploads.clear();
    _activeUploads.clear();
  }

  /// Route one request and normalize all endpoint errors to JSON.
  Future<void> handleRequest(HttpRequest request) async {
    _setResponseHeaders(request.response);
    final path = request.uri.path;
    try {
      if (!isActive()) {
        throw const LanWebShareHttpException(
          HttpStatus.serviceUnavailable,
          'Web Share service is shutting down.',
        );
      }
      if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
        _requireToken(request, allowQueryParameter: true);
        request.response.headers.contentType = ContentType.html;
        request.response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; style-src 'unsafe-inline'; "
              "script-src 'unsafe-inline'; connect-src 'self'; "
              "img-src data:; base-uri 'none'; form-action 'none'; "
              "frame-ancestors 'none'",
        );
        request.response.headers.set('X-Frame-Options', 'DENY');
        request.response.write(buildHtml());
        await request.response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/web/meta') {
        await _handleWebMetaRequest(request);
        return;
      }
      if (request.method == 'POST' && path == '/api/web/upload') {
        await _handleWebUploadRequest(request);
        return;
      }
      throw const LanWebShareHttpException(
        HttpStatus.notFound,
        'Web Share endpoint not found.',
      );
    } on LanWebShareHttpException catch (error) {
      await _prepareErrorResponse(request);
      await _writeJson(request.response, error.statusCode, {
        'code': lanHttpErrorCode(error.statusCode).wireValue,
        'message': error.message,
        'operation': _operationForPath(path).wireName,
      });
    } catch (error) {
      await _prepareErrorResponse(request);
      logger(
        '[LanWebShareRequestHandler] request failed: '
        'errorType=${error.runtimeType}',
      );
      try {
        await _writeJson(request.response, HttpStatus.internalServerError, {
          'code': NetworkErrorCode.ioError.wireValue,
          'message': 'WebShare request failed.',
          'operation': _operationForPath(path).wireName,
        });
      } catch (_) {}
    }
  }

  /// Read a body with an explicit byte bound and idle timeout.
  Future<Uint8List> readBoundedBody(
    HttpRequest request, {
    required int maxBytes,
  }) async {
    if (request.contentLength > maxBytes) {
      throw const LanWebShareHttpException(
        HttpStatus.requestEntityTooLarge,
        'Request body is too large.',
      );
    }
    _bodyReadStarted[request] = true;
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request.timeout(
      LanWebShareLimits.requestBodyIdleTimeout,
      onTimeout: (sink) {
        sink
          ..addError(
            const LanWebShareHttpException(
              HttpStatus.requestTimeout,
              'Request body timed out.',
            ),
          )
          ..close();
      },
    )) {
      total += chunk.length;
      if (total > maxBytes) {
        throw const LanWebShareHttpException(
          HttpStatus.requestEntityTooLarge,
          'Request body is too large.',
        );
      }
      builder.add(chunk);
    }
    _bodyFullyConsumed[request] = true;
    return builder.takeBytes();
  }

  /// Decode an object-shaped JSON metadata body.
  Map<String, dynamic> decodeJson(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected an object.');
      }
      return decoded;
    } on FormatException {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'Malformed Web Share metadata.',
      );
    }
  }

  /// Decode the opt-in browser E2E marker, rejecting ambiguous values.
  bool isEncryptedRequest(HttpRequest request) {
    final value = request.headers.value('x-e2e-pubkey');
    if (value == null) return false;
    if (value == '1') return true;
    throw const LanWebShareHttpException(
      HttpStatus.badRequest,
      'Invalid encryption header.',
    );
  }

  /// Validate an endpoint message identifier before using it as a map key.
  String validateMessageId(Object? value) {
    final messageId = value is String ? value.trim() : '';
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(messageId)) {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'Invalid Web Share message ID.',
      );
    }
    return messageId;
  }

  /// Validate a sender-provided basename before it reaches storage.
  String validateFileName(Object? value) {
    final fileName = value is String ? value.trim() : '';
    if (fileName.isEmpty ||
        fileName.length > 255 ||
        fileName == '.' ||
        fileName == '..' ||
        RegExp(r'[\x00-\x1F/\\]').hasMatch(fileName)) {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'Invalid Web Share file name.',
      );
    }
    return fileName;
  }

  /// URI-decode and validate the upload filename header.
  String decodeFileNameHeader(String? value) {
    if (value == null || value.length > 1024) {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'A valid file name header is required.',
      );
    }
    try {
      return validateFileName(Uri.decodeComponent(value));
    } on LanWebShareHttpException {
      rethrow;
    } catch (_) {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'Invalid encoded file name.',
      );
    }
  }

  void _prunePendingUploads() {
    _pendingUploads.removeWhere((_, upload) => upload.isExpired);
  }

  void _requireUploadReservationAvailable(String messageId) {
    _prunePendingUploads();
    if (_pendingUploads.containsKey(messageId) ||
        _activeUploads.containsKey(messageId)) {
      throw const LanWebShareHttpException(
        HttpStatus.conflict,
        'A Web Share upload with this ID is already pending or active.',
      );
    }
    if (_pendingUploads.length + _activeUploads.length >= maxPendingUploads) {
      throw const LanWebShareHttpException(
        HttpStatus.tooManyRequests,
        'Too many Web Share uploads are pending or active.',
      );
    }
  }

  Future<Uint8List> _decrypt(Uint8List encrypted) async {
    try {
      return await decryptPayload(encrypted);
    } catch (_) {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'Invalid encrypted payload.',
      );
    }
  }

  /// Drain a bounded rejected body before writing its response.
  ///
  /// A browser may already have sent the body when metadata or filename
  /// validation fails. Draining only the accepted-size window keeps the
  /// connection reusable without turning a rejected request into an unbounded
  /// memory or socket wait.
  Future<bool> _drainRejectedBody(HttpRequest request) async {
    final maxBytes = LanWebShareLimits.maxRejectedBodyDrainBytes;
    if (request.contentLength == 0) return true;
    if (_bodyFullyConsumed[request] == true) return true;
    // A single-subscription HttpRequest cannot be safely listened to twice.
    // If normal bounded reading already started and failed, close this
    // response instead of risking a second listener or an unbounded wait.
    if (_bodyReadStarted[request] == true) return false;
    // A declared body larger than the bounded drain window cannot be made
    // reusable safely.  Close this response after emitting the error rather
    // than waiting for an attacker-controlled body to finish.
    if (request.contentLength > maxBytes) return false;
    var total = 0;
    _bodyReadStarted[request] = true;
    try {
      await for (final chunk in request.timeout(
        LanWebShareLimits.rejectedBodyDrainTimeout,
      )) {
        total += chunk.length;
        if (total > maxBytes) return false;
      }
      _bodyFullyConsumed[request] = true;
      return true;
    } catch (_) {}
    return false;
  }

  Future<void> _prepareErrorResponse(HttpRequest request) async {
    final bodyFullyConsumed = await _drainRejectedBody(request);
    if (!bodyFullyConsumed) {
      request.response.persistentConnection = false;
      request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    }
  }

  Future<void> _handleWebMetaRequest(HttpRequest request) async {
    _requireToken(request);
    final encrypted = isEncryptedRequest(request);
    final rawBody = await readBoundedBody(
      request,
      maxBytes:
          LanWebShareLimits.maxControlBodyBytes +
          (encrypted ? e2eEnvelopeOverheadBytes : 0),
    );
    final plainBody = encrypted ? await _decrypt(rawBody) : rawBody;
    _requireToken(request);
    if (plainBody.length > LanWebShareLimits.maxControlBodyBytes) {
      throw const LanWebShareHttpException(
        HttpStatus.requestEntityTooLarge,
        'Web Share metadata is too large.',
      );
    }

    final json = decodeJson(plainBody);
    final messageId = validateMessageId(json['id']);
    final fileName = validateFileName(json['fileName']);
    final senderId = json['senderId'];
    final receiverId = json['receiverId'];
    final payloadType = json['payloadType'];
    final rawFileSize = json['fileSize'];
    if (senderId != 'web-browser' ||
        receiverId != currentDeviceId ||
        payloadType != 'file' ||
        rawFileSize is! num ||
        !rawFileSize.isFinite ||
        rawFileSize != rawFileSize.toInt()) {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'Invalid Web Share metadata.',
      );
    }
    final fileSize = rawFileSize.toInt();
    if (fileSize < 0 ||
        fileSize > LanWebShareLimits.maxAdvertisedFileBytes ||
        (encrypted && fileSize > LanWebShareLimits.maxEncryptedUploadBytes)) {
      throw const LanWebShareHttpException(
        HttpStatus.requestEntityTooLarge,
        'Web Share file exceeds the allowed size.',
      );
    }

    _requireUploadReservationAvailable(messageId);
    if (!await hasSufficientSpace(fileSize)) {
      throw const LanWebShareHttpException(
        HttpStatus.insufficientStorage,
        'Insufficient storage.',
      );
    }
    _requireToken(request);

    final message = LanWebShareMessage(
      id: messageId,
      senderId: 'web-browser',
      senderAlias: '网页端浏览器',
      receiverId: currentDeviceId,
      fileName: fileName,
      fileSize: fileSize,
      bytesTransferred: 0,
      status: LanWebShareMessageStatus.pending,
      createdAt: DateTime.now(),
    );
    // Disk inspection is asynchronous; re-check before registering so two
    // concurrent metadata requests cannot cross the duplicate/capacity gate.
    _requireUploadReservationAvailable(messageId);
    _pendingUploads[messageId] = _PendingWebUpload(
      messageId: messageId,
      fileName: fileName,
      expectedBytes: fileSize,
      encrypted: encrypted,
      expiresAt: DateTime.now().add(pendingUploadTtl),
    );
    try {
      onIncomingMessage(message);
    } catch (_) {
      _pendingUploads.remove(messageId);
      rethrow;
    }

    await _writeJson(request.response, HttpStatus.ok, {'id': message.id});
  }

  Future<void> _handleWebUploadRequest(HttpRequest request) async {
    _requireToken(request);
    final messageId = validateMessageId(request.headers.value('x-message-id'));
    final fileName = decodeFileNameHeader(request.headers.value('x-file-name'));
    final encrypted = isEncryptedRequest(request);
    _prunePendingUploads();
    final pending = _pendingUploads[messageId];
    if (pending == null) {
      throw const LanWebShareHttpException(
        HttpStatus.conflict,
        'Upload metadata is missing or expired.',
      );
    }
    if (pending.fileName != fileName || pending.encrypted != encrypted) {
      throw const LanWebShareHttpException(
        HttpStatus.badRequest,
        'Upload does not match its accepted metadata.',
      );
    }

    final expectedBodyBytes =
        pending.expectedBytes + (encrypted ? e2eEnvelopeOverheadBytes : 0);
    final declaredLength = request.contentLength;
    if (declaredLength >= 0 && declaredLength != expectedBodyBytes) {
      throw LanWebShareHttpException(
        declaredLength > expectedBodyBytes
            ? HttpStatus.requestEntityTooLarge
            : HttpStatus.badRequest,
        'Upload length does not match its accepted metadata.',
      );
    }

    // Atomically move the lease to active before the first await. This blocks
    // replay and retains bounded capacity while the request streams.
    _pendingUploads.remove(messageId);
    _activeUploads[messageId] = pending;
    File? targetFile;
    var completed = false;
    var bytesReceived = 0;
    try {
      targetFile = await createTargetFile(fileName);
      if (encrypted) {
        final encryptedBody = await readBoundedBody(
          request,
          maxBytes: expectedBodyBytes,
        );
        if (encryptedBody.length != expectedBodyBytes) {
          throw const LanWebShareHttpException(
            HttpStatus.badRequest,
            'Encrypted upload is incomplete.',
          );
        }
        final plainBytes = await _decrypt(encryptedBody);
        if (plainBytes.length != pending.expectedBytes) {
          throw const LanWebShareHttpException(
            HttpStatus.badRequest,
            'Decrypted upload length does not match metadata.',
          );
        }
        await targetFile.writeAsBytes(plainBytes, flush: true);
        bytesReceived = plainBytes.length;
      } else {
        final sink = targetFile.openWrite();
        var overrun = false;
        _bodyReadStarted[request] = true;
        try {
          await for (final chunk in request.timeout(
            LanWebShareLimits.requestBodyIdleTimeout,
            onTimeout: (sink) {
              sink
                ..addError(
                  const LanWebShareHttpException(
                    HttpStatus.requestTimeout,
                    'Upload body timed out.',
                  ),
                )
                ..close();
            },
          )) {
            bytesReceived += chunk.length;
            if (bytesReceived > pending.expectedBytes) {
              overrun = true;
              break;
            }
            sink.add(chunk);
          }
          if (!overrun) _bodyFullyConsumed[request] = true;
          if (overrun || bytesReceived > pending.expectedBytes) {
            throw const LanWebShareHttpException(
              HttpStatus.requestEntityTooLarge,
              'Upload exceeds its accepted size.',
            );
          }
          if (bytesReceived != pending.expectedBytes) {
            throw const LanWebShareHttpException(
              HttpStatus.badRequest,
              'Upload is incomplete.',
            );
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      }

      _requireToken(request);

      onMessageProgress(
        LanWebShareMessage(
          id: pending.messageId,
          senderId: 'web-browser',
          senderAlias: '网页端浏览器',
          receiverId: currentDeviceId,
          fileName: pending.fileName,
          localPath: targetFile.path,
          bytesTransferred: bytesReceived,
          fileSize: pending.expectedBytes,
          status: LanWebShareMessageStatus.completed,
          createdAt: DateTime.now(),
        ),
      );
      completed = true;

      await _writeJson(request.response, HttpStatus.ok, {
        'messageId': messageId,
        'bytesReceived': bytesReceived,
      });
    } catch (_) {
      if (!completed && isActive()) {
        onMessageProgress(
          LanWebShareMessage(
            id: pending.messageId,
            senderId: 'web-browser',
            senderAlias: '网页端浏览器',
            receiverId: currentDeviceId,
            fileName: pending.fileName,
            localPath: null,
            bytesTransferred: bytesReceived,
            fileSize: pending.expectedBytes,
            status: LanWebShareMessageStatus.failed,
            createdAt: DateTime.now(),
          ),
        );
      }
      rethrow;
    } finally {
      if (identical(_activeUploads[messageId], pending)) {
        _activeUploads.remove(messageId);
      }
      if (!completed && targetFile != null) {
        try {
          await deleteFile(targetFile.path);
        } catch (_) {}
      }
    }
  }

  void _requireToken(HttpRequest request, {bool allowQueryParameter = false}) {
    if (!isActive()) {
      throw const LanWebShareHttpException(
        HttpStatus.serviceUnavailable,
        'Web Share service is shutting down.',
      );
    }
    final provided = allowQueryParameter
        ? request.uri.queryParameters['access']
        : request.headers.value(webShareTokenHeader);
    if (provided == null || !_constantTimeEquals(webShareToken, provided)) {
      throw const LanWebShareHttpException(
        HttpStatus.unauthorized,
        'A valid Web Share access token is required.',
      );
    }
  }

  static bool _constantTimeEquals(String expected, String provided) {
    var difference = expected.length ^ provided.length;
    for (var i = 0; i < expected.length; i++) {
      final providedCode = i < provided.length ? provided.codeUnitAt(i) : 0;
      difference |= expected.codeUnitAt(i) ^ providedCode;
    }
    return difference == 0;
  }

  static NetworkOperation _operationForPath(String path) {
    return switch (path) {
      '/api/web/meta' => NetworkOperation.webShareSendMeta,
      '/api/web/upload' => NetworkOperation.webShareSendFile,
      _ => NetworkOperation.webShareRequest,
    };
  }

  static void _setResponseHeaders(HttpResponse response) {
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('Pragma', 'no-cache');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'no-referrer');
  }

  static Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
