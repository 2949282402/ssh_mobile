import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encrypts one bounded relay chunk at a time. Nonces are deterministic per
/// transfer/sequence, while the random base nonce is unique for every offer.
class RelayChunkCipher {
  RelayChunkCipher({required Uint8List key, required Uint8List baseNonce})
    : _key = Uint8List.fromList(key),
      _baseNonce = Uint8List.fromList(baseNonce) {
    if (_key.length != 32 || _baseNonce.length != 4) {
      throw ArgumentError(
        'Relay cipher requires a 32-byte key and 4-byte nonce prefix.',
      );
    }
  }

  static const int maxPlaintextChunkBytes = 512 * 1024;
  final Uint8List _key;
  final Uint8List _baseNonce;
  final AesGcm _algorithm = AesGcm.with256bits();

  Future<Uint8List> encrypt({
    required String sessionId,
    required int sequence,
    required Uint8List plaintext,
  }) async {
    if (plaintext.length > maxPlaintextChunkBytes || sequence < 0) {
      throw ArgumentError('Invalid relay plaintext chunk.');
    }
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: SecretKey(_key),
      nonce: _nonce(sequence),
      aad: _aad(sessionId, sequence),
    );
    return Uint8List.fromList(box.cipherText + box.mac.bytes);
  }

  Future<Uint8List> decrypt({
    required String sessionId,
    required int sequence,
    required Uint8List ciphertext,
  }) async {
    if (ciphertext.length < 16 || sequence < 0) {
      throw ArgumentError('Invalid relay ciphertext chunk.');
    }
    final split = ciphertext.length - 16;
    final box = SecretBox(
      ciphertext.sublist(0, split),
      nonce: _nonce(sequence),
      mac: Mac(ciphertext.sublist(split)),
    );
    return Uint8List.fromList(
      await _algorithm.decrypt(
        box,
        secretKey: SecretKey(_key),
        aad: _aad(sessionId, sequence),
      ),
    );
  }

  Uint8List _nonce(int sequence) {
    final data = ByteData(12)..setUint64(4, sequence, Endian.big);
    final result = Uint8List.fromList(data.buffer.asUint8List());
    result.setRange(0, 4, _baseNonce);
    return result;
  }

  Uint8List _aad(String sessionId, int sequence) {
    final id = _sessionIdBytes(sessionId);
    final data = ByteData(24)..setUint64(16, sequence, Endian.big);
    data.buffer.asUint8List().setRange(0, 16, id);
    return data.buffer.asUint8List();
  }
}

Uint8List relaySessionIdBytes(String sessionId) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(sessionId)) {
    throw ArgumentError.value(
      sessionId,
      'sessionId',
      'must be 16-byte lowercase hex',
    );
  }
  return Uint8List.fromList(
    List<int>.generate(
      16,
      (index) =>
          int.parse(sessionId.substring(index * 2, index * 2 + 2), radix: 16),
    ),
  );
}

Uint8List _sessionIdBytes(String sessionId) => relaySessionIdBytes(sessionId);
