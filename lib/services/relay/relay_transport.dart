import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../lan_share/lan_security_service.dart';
import '../lan_share/lan_share_models.dart';
import 'relay_chunk_cipher.dart';
import 'relay_client.dart';
import 'relay_models.dart';

/// E2E SFTP relay sender. The caller owns the SFTP stream and explicitly
/// chooses this transport; it never falls back to a LAN connection.
class RelayTransport {
  RelayTransport({
    required this.client,
    required this.securityService,
    this.responseTimeout = const Duration(seconds: 30),
  });

  final RelayClient client;
  final LanSecurityService securityService;
  final Duration responseTimeout;

  /// Decodes an opaque offer locally. Callers should show the returned metadata
  /// and only call [accept] after explicit user approval.
  Future<RelayIncomingOffer?> decodeIncomingOffer(
    RelayControlFrame frame,
  ) async {
    if (frame.type != RelayControlType.offer || frame.payload == null) {
      return null;
    }
    try {
      final clear = await securityService.decryptE2E(frame.payload!);
      final value = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      final name = value['file_name'] as String?;
      final size = (value['file_size'] as num?)?.toInt();
      final key = value['content_key'] as String?;
      final prefix = value['nonce_prefix'] as String?;
      final sessionId = value['session_id'] as String?;
      final senderId = value['sender_id'] as String?;
      final receiverId = value['receiver_id'] as String?;
      if (value['v'] != 1 ||
          name == null ||
          !_isSafeRelayFileName(name) ||
          size == null ||
          size < 0 ||
          key == null ||
          prefix == null ||
          sessionId != frame.sessionId ||
          senderId != frame.peerId ||
          receiverId != client.currentDeviceId) {
        return null;
      }
      final keyBytes = base64Url.decode(base64Url.normalize(key));
      final prefixBytes = base64Url.decode(base64Url.normalize(prefix));
      if (keyBytes.length != 32 || prefixBytes.length != 4) return null;
      return RelayIncomingOffer(
        sessionId: frame.sessionId,
        senderId: senderId!,
        fileName: name,
        totalBytes: size,
        cipher: RelayChunkCipher(
          key: Uint8List.fromList(keyBytes),
          baseNonce: Uint8List.fromList(prefixBytes),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> accept(RelayIncomingOffer offer) => client.sendControl(
    RelayControlFrame(
      type: RelayControlType.accept,
      sessionId: offer.sessionId,
    ),
  );

  Future<void> acknowledgeComplete(RelayIncomingOffer offer) async {
    if (!offer.isComplete) {
      throw StateError('Relay transfer is incomplete.');
    }
    await client.sendControl(
      RelayControlFrame(
        type: RelayControlType.completeAck,
        sessionId: offer.sessionId,
      ),
    );
  }

  /// Rejects or aborts an active transfer using the current Relay protocol.
  /// Cancellation is best-effort because the server also expires sessions.
  Future<void> cancel(String sessionId) => _cancelSession(sessionId);

  /// Uses only the X25519 key pinned during reciprocal LAN pairing. A missing
  /// key means the peer must be re-paired before a public transfer is allowed.
  Future<bool> sendFileToPairedPeer({
    required LanDevice target,
    required String fileName,
    required int totalBytes,
    required Stream<List<int>> stream,
    void Function(int bytesSent)? onProgress,
    String? sessionId,
  }) async {
    final peerPublicKey = await securityService.getPeerX25519PublicKey(
      target.id,
    );
    if (peerPublicKey == null) return false;
    return sendFile(
      target: target,
      fileName: fileName,
      totalBytes: totalBytes,
      stream: stream,
      peerPublicKey: peerPublicKey,
      onProgress: onProgress,
      sessionId: sessionId,
    );
  }

  Future<bool> sendFile({
    required LanDevice target,
    required String fileName,
    required int totalBytes,
    required Stream<List<int>> stream,
    required Uint8List peerPublicKey,
    void Function(int bytesSent)? onProgress,
    String? sessionId,
  }) async {
    if (!client.isConnected || totalBytes < 0 || peerPublicKey.length != 32) {
      return false;
    }
    if (!_isSafeRelayFileName(fileName)) return false;
    final effectiveSessionId = sessionId ?? _newSessionId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(effectiveSessionId)) return false;
    final contentKey = _randomBytes(32);
    final noncePrefix = _randomBytes(4);
    final encryptedOffer = await securityService.encryptE2EFor(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 1,
            'session_id': effectiveSessionId,
            'sender_id': client.currentDeviceId,
            'receiver_id': target.id,
            'file_name': fileName,
            'file_size': totalBytes,
            'content_key': base64UrlEncode(contentKey).replaceAll('=', ''),
            'nonce_prefix': base64UrlEncode(noncePrefix).replaceAll('=', ''),
          }),
        ),
      ),
      peerPublicKey,
    );
    final acceptance = Completer<bool>();
    final completion = Completer<bool>();
    final subscription = client.controls.listen((frame) {
      if (frame.sessionId != effectiveSessionId || frame.peerId != target.id) {
        return;
      }
      if (frame.type == RelayControlType.accept && !acceptance.isCompleted) {
        acceptance.complete(true);
      } else if (frame.type == RelayControlType.cancel) {
        if (!acceptance.isCompleted) acceptance.complete(false);
        if (!completion.isCompleted) completion.complete(false);
      } else if (frame.type == RelayControlType.completeAck &&
          !completion.isCompleted) {
        completion.complete(true);
      }
    });
    await client.sendControl(
      RelayControlFrame(
        type: RelayControlType.offer,
        sessionId: effectiveSessionId,
        targetId: target.id,
        payload: encryptedOffer,
      ),
    );
    final accepted = await acceptance.future.timeout(
      responseTimeout,
      onTimeout: () => false,
    );
    if (!accepted) {
      await subscription.cancel();
      await _cancelSession(effectiveSessionId);
      return false;
    }
    final cipher = RelayChunkCipher(key: contentKey, baseNonce: noncePrefix);
    var sent = 0;
    var sequence = 0;
    try {
      await for (final chunk in stream) {
        if (chunk.isEmpty) {
          continue;
        }
        if (chunk.length > RelayChunkCipher.maxPlaintextChunkBytes ||
            sent + chunk.length > totalBytes) {
          return false;
        }
        final encrypted = await cipher.encrypt(
          sessionId: effectiveSessionId,
          sequence: sequence++,
          plaintext: Uint8List.fromList(chunk),
        );
        client.sendBinary(
          RelayBinaryFrame(
            kind: 0x10,
            sessionId: effectiveSessionId,
            sequence: sequence - 1,
            payload: encrypted,
          ),
        );
        sent += chunk.length;
        onProgress?.call(sent);
      }
      if (sent != totalBytes) return false;
      await client.sendControl(
        RelayControlFrame(
          type: RelayControlType.complete,
          sessionId: effectiveSessionId,
        ),
      );
      return completion.future.timeout(responseTimeout, onTimeout: () => false);
    } finally {
      await subscription.cancel();
      await _cancelSession(effectiveSessionId);
    }
  }

  Future<void> _cancelSession(String sessionId) async {
    if (!client.isConnected) return;
    try {
      await client.sendControl(
        RelayControlFrame(type: RelayControlType.cancel, sessionId: sessionId),
      );
    } on Object {
      // The socket may close between isConnected and sendControl. Cancellation
      // is best-effort because the server also expires all in-memory sessions.
    }
  }
}

/// Receiver-side state is intentionally in memory. A view model can persist
/// only the offset/path checkpoint through encrypted storage between sessions.
class RelayIncomingOffer {
  RelayIncomingOffer({
    required this.sessionId,
    required this.senderId,
    required this.fileName,
    required this.totalBytes,
    required this.cipher,
  });

  final String sessionId;
  final String senderId;
  final String fileName;
  final int totalBytes;
  final RelayChunkCipher cipher;
  int _nextSequence = 0;
  int _receivedBytes = 0;

  int get receivedBytes => _receivedBytes;
  bool get isComplete => _receivedBytes == totalBytes;

  Future<Uint8List> decryptNext(RelayBinaryFrame frame) async {
    if (frame.kind != 0x10 ||
        frame.sessionId != sessionId ||
        frame.sequence != _nextSequence) {
      throw StateError(
        'Relay chunk is replayed, reordered, or for another session.',
      );
    }
    final plaintext = await cipher.decrypt(
      sessionId: sessionId,
      sequence: frame.sequence,
      ciphertext: frame.payload,
    );
    if (plaintext.isEmpty) {
      throw StateError('Relay chunks must not be empty.');
    }
    if (_receivedBytes + plaintext.length > totalBytes) {
      throw StateError('Relay transfer exceeds its declared size.');
    }
    _nextSequence++;
    _receivedBytes += plaintext.length;
    return plaintext;
  }
}

String _newSessionId() => List<int>.generate(
  16,
  (_) => Random.secure().nextInt(256),
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
Uint8List _randomBytes(int length) => Uint8List.fromList(
  List<int>.generate(length, (_) => Random.secure().nextInt(256)),
);

bool _isSafeRelayFileName(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains(r'\') &&
    !value.contains('\u0000');
