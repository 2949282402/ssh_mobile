import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;

/// One-use SRP-6a state. It must never be reused for another offer.
class LanPairingEphemeralKeyPair {
  final Object engine;
  final Uint8List salt;
  final Uint8List publicValue;
  final bool isClient;
  final int slot;
  final BigInt? sharedSecret;

  const LanPairingEphemeralKeyPair({
    required this.engine,
    required this.salt,
    required this.publicValue,
    required this.isClient,
    required this.slot,
    this.sharedSecret,
  });
}

class LanPairingSessionSecrets {
  final Uint8List sessionKey;
  final Uint8List clientConfirmationKey;
  final Uint8List serverConfirmationKey;
  final Uint8List transcript;

  const LanPairingSessionSecrets({
    required this.sessionKey,
    required this.clientConfirmationKey,
    required this.serverConfirmationKey,
    required this.transcript,
  });
}

/// RFC 5054 SRP-6a plus transcript-bound mutual key confirmation.
///
/// The 3072-bit group is fixed locally. Each rotating PIN slot uses a
/// different salt and independent SRP exponent, so a captured exchange does
/// not expose an offline PIN verifier and cannot be reflected across slots.
class LanPairingCrypto {
  static const int protocolVersion = 3;
  static const int publicValueBytes = 384;
  static const int maxServerOffers = 2;
  static const int credentialTtlMillis = 15000;
  static const String _domainLabel = 'ssh-mobile-lan-pair';
  static const String suite = 'srp6a-rfc5054-3072-sha256-hkdf-hmac';

  static final pc.SRP6GroupParameters _group =
      pc.SRP6StandardGroups.rfc5054_3072;
  static final Random _secureRandom = Random.secure();

  static LanPairingEphemeralKeyPair generateClientKeyPair({
    required String pin,
    required String clientContext,
    required int slot,
  }) {
    _validatePinAndSlot(pin, slot);
    final salt = _pairingSalt(clientContext, slot);
    final client = pc.SRP6Client(
      group: _group,
      digest: pc.SHA256Digest(),
      random: _newSecureRandom(),
    );
    final publicValue = client.generateClientCredentials(
      salt,
      _identity(clientContext),
      Uint8List.fromList(utf8.encode(pin)),
    );
    if (publicValue == null || !_isValidPublicInteger(publicValue)) {
      throw const FormatException('Invalid LAN pairing client value');
    }
    return LanPairingEphemeralKeyPair(
      engine: client,
      salt: salt,
      publicValue: _bigIntToFixedBytes(publicValue, publicValueBytes),
      isClient: true,
      slot: slot,
    );
  }

  static LanPairingEphemeralKeyPair generateServerKeyPair({
    required String pin,
    required String clientContext,
    required int slot,
    required Uint8List clientPublicValue,
  }) {
    _validatePinAndSlot(pin, slot);
    final clientPublicInteger = _decodePublicValue(clientPublicValue);
    final salt = _pairingSalt(clientContext, slot);
    final verifier =
        pc.SRP6VerifierGenerator(
          group: _group,
          digest: pc.SHA256Digest(),
        ).generateVerifier(
          salt,
          _identity(clientContext),
          Uint8List.fromList(utf8.encode(pin)),
        );
    final server = pc.SRP6Server(
      group: _group,
      v: verifier,
      digest: pc.SHA256Digest(),
      random: _newSecureRandom(),
    );
    final publicValue = server.generateServerCredentials();
    if (publicValue == null || !_isValidPublicInteger(publicValue)) {
      throw const FormatException('Invalid LAN pairing server value');
    }
    final sharedSecret = server.calculateSecret(clientPublicInteger);
    if (sharedSecret == null || sharedSecret <= BigInt.zero) {
      throw const FormatException('Invalid LAN pairing shared secret');
    }
    return LanPairingEphemeralKeyPair(
      engine: server,
      salt: salt,
      publicValue: _bigIntToFixedBytes(publicValue, publicValueBytes),
      isClient: false,
      slot: slot,
      sharedSecret: sharedSecret,
    );
  }

  static LanPairingSessionSecrets deriveSessionSecrets({
    required LanPairingEphemeralKeyPair localKeyPair,
    required Uint8List remotePublicValue,
    required String associatedData,
  }) {
    final remoteInteger = _decodePublicValue(remotePublicValue);
    late final BigInt sharedSecret;
    if (localKeyPair.isClient) {
      final client = localKeyPair.engine;
      if (client is! pc.SRP6Client) {
        throw const FormatException('Invalid LAN pairing client state');
      }
      final calculated = client.calculateSecret(remoteInteger);
      if (calculated == null || calculated <= BigInt.zero) {
        throw const FormatException('Invalid LAN pairing shared secret');
      }
      sharedSecret = calculated;
    } else {
      final calculated = localKeyPair.sharedSecret;
      if (calculated == null || calculated <= BigInt.zero) {
        throw const FormatException('Invalid LAN pairing server state');
      }
      sharedSecret = calculated;
    }

    final transcript = Uint8List.fromList(utf8.encode(associatedData));
    final transcriptHash = crypto.sha256.convert(transcript).bytes;
    final inputKey = _bigIntToFixedBytes(sharedSecret, publicValueBytes);
    final keyMaterial = _hkdfSha256(
      inputKey,
      salt: transcriptHash,
      info: utf8.encode('$_domainLabel\u0000session-keys'),
      length: 64,
    );
    return LanPairingSessionSecrets(
      sessionKey: Uint8List.fromList(keyMaterial.sublist(0, 32)),
      clientConfirmationKey: Uint8List.fromList(keyMaterial.sublist(32, 48)),
      serverConfirmationKey: Uint8List.fromList(keyMaterial.sublist(48, 64)),
      transcript: transcript,
    );
  }

  static String createClientProof(LanPairingSessionSecrets secrets) =>
      _createProof(secrets.clientConfirmationKey, secrets.transcript);

  static String createServerProof(LanPairingSessionSecrets secrets) =>
      _createProof(secrets.serverConfirmationKey, secrets.transcript);

  static bool verifyClientProof(
    LanPairingSessionSecrets secrets,
    String proof,
  ) => _verifyProof(secrets.clientConfirmationKey, secrets.transcript, proof);

  static bool verifyServerProof(
    LanPairingSessionSecrets secrets,
    String proof,
  ) => _verifyProof(secrets.serverConfirmationKey, secrets.transcript, proof);

  static String randomToken({int byteLength = 24}) {
    final bytes = List<int>.generate(
      byteLength,
      (_) => _secureRandom.nextInt(256),
      growable: false,
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<String> encryptCredential(
    Map<String, dynamic> credential,
    Uint8List sessionKey, {
    required String associatedData,
  }) async {
    final algorithm = AesGcm.with256bits();
    final nonce = algorithm.newNonce();
    final box = await algorithm.encrypt(
      utf8.encode(jsonEncode(credential)),
      secretKey: SecretKey(sessionKey),
      nonce: nonce,
      aad: utf8.encode(associatedData),
    );
    return base64.encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Map<String, dynamic>> decryptCredential(
    String encoded,
    Uint8List sessionKey, {
    required String associatedData,
  }) async {
    const nonceLength = 12;
    const macLength = 16;
    late final Uint8List bytes;
    try {
      bytes = base64.decode(encoded);
    } catch (_) {
      throw const FormatException('Invalid LAN pairing credential');
    }
    if (bytes.length < nonceLength + macLength) {
      throw const FormatException('Invalid LAN pairing credential');
    }
    final nonce = bytes.sublist(0, nonceLength);
    final cipherText = bytes.sublist(nonceLength, bytes.length - macLength);
    final mac = Mac(bytes.sublist(bytes.length - macLength));
    try {
      final clearText = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: SecretKey(sessionKey),
        aad: utf8.encode(associatedData),
      );
      final decoded = jsonDecode(utf8.decode(clearText));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    } catch (_) {
      throw const FormatException('Invalid LAN pairing credential');
    }
  }

  static String clientContext({
    required String senderDeviceId,
    required String targetDeviceId,
    required String nonce,
    required String alias,
    required String os,
    required int port,
    required bool isInitiator,
    required String senderCertFingerprint,
  }) {
    return _canonical([
      _domainLabel,
      protocolVersion,
      suite,
      'client-context',
      senderDeviceId,
      targetDeviceId,
      nonce,
      alias,
      os,
      port,
      isInitiator,
      senderCertFingerprint.toLowerCase(),
    ]);
  }

  static String sessionAssociatedData({
    required String clientContext,
    required String handshakeId,
    required int slot,
    required Uint8List salt,
    required Uint8List clientPublicValue,
    required Uint8List serverPublicValue,
    required String serverCertFingerprint,
  }) {
    return _canonical([
      _domainLabel,
      protocolVersion,
      suite,
      'session',
      clientContext,
      handshakeId,
      slot,
      base64.encode(salt),
      base64.encode(clientPublicValue),
      base64.encode(serverPublicValue),
      serverCertFingerprint.toLowerCase(),
    ]);
  }

  static String credentialAssociatedData({
    required String handshakeId,
    required String nonce,
    required String issuerDeviceId,
    required String recipientDeviceId,
  }) {
    return _canonical([
      _domainLabel,
      protocolVersion,
      'credential',
      handshakeId,
      nonce,
      issuerDeviceId,
      recipientDeviceId,
    ]);
  }

  static String requestHash(String clientContext) =>
      crypto.sha256.convert(utf8.encode(clientContext)).toString();

  static bool isValidPublicValueForTesting(Uint8List value) {
    try {
      _decodePublicValue(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Uint8List _pairingSalt(String clientContext, int slot) {
    return Uint8List.fromList(
      crypto.sha256
          .convert(
            utf8.encode(
              '$_domainLabel\u0000$protocolVersion\u0000salt\u0000$slot\u0000$clientContext',
            ),
          )
          .bytes,
    );
  }

  static Uint8List _identity(String clientContext) => Uint8List.fromList(
    utf8.encode('$_domainLabel\u0000$protocolVersion\u0000$clientContext'),
  );

  static void _validatePinAndSlot(String pin, int slot) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin) ||
        slot < 0 ||
        slot >= maxServerOffers) {
      throw const FormatException('Invalid LAN pairing PIN slot');
    }
  }

  static bool _isValidPublicInteger(BigInt value) =>
      value > BigInt.zero && value < _group.N;

  static BigInt _decodePublicValue(Uint8List value) {
    if (value.length != publicValueBytes) {
      throw const FormatException('Invalid LAN pairing public value');
    }
    final decoded = _bytesToBigInt(value);
    if (!_isValidPublicInteger(decoded) || decoded % _group.N == BigInt.zero) {
      throw const FormatException('Invalid LAN pairing public value');
    }
    if (!_constantTimeEquals(
      value,
      _bigIntToFixedBytes(decoded, publicValueBytes),
    )) {
      throw const FormatException('Non-canonical LAN pairing public value');
    }
    return decoded;
  }

  static pc.SecureRandom _newSecureRandom() {
    final random = pc.FortunaRandom();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => _secureRandom.nextInt(256)),
    );
    random.seed(pc.KeyParameter(seed));
    return random;
  }

  static String _createProof(Uint8List key, Uint8List transcript) {
    return base64.encode(
      crypto.Hmac(crypto.sha256, key).convert(transcript).bytes,
    );
  }

  static bool _verifyProof(Uint8List key, Uint8List transcript, String proof) {
    late final Uint8List received;
    try {
      received = base64.decode(proof);
    } catch (_) {
      return false;
    }
    final expected = base64.decode(_createProof(key, transcript));
    return _constantTimeEquals(expected, received);
  }

  static Uint8List _hkdfSha256(
    List<int> inputKeyMaterial, {
    required List<int> salt,
    required List<int> info,
    required int length,
  }) {
    final pseudoRandomKey = crypto.Hmac(
      crypto.sha256,
      salt,
    ).convert(inputKeyMaterial).bytes;
    final output = BytesBuilder(copy: false);
    var previous = <int>[];
    var counter = 1;
    while (output.length < length) {
      previous = crypto.Hmac(
        crypto.sha256,
        pseudoRandomKey,
      ).convert([...previous, ...info, counter]).bytes;
      output.add(previous);
      counter++;
    }
    return Uint8List.fromList(output.takeBytes().sublist(0, length));
  }

  static Uint8List _bigIntToFixedBytes(BigInt value, int length) {
    final output = Uint8List(length);
    var remaining = value;
    for (var index = length - 1; index >= 0; index--) {
      output[index] = (remaining & BigInt.from(0xff)).toInt();
      remaining >>= 8;
    }
    if (remaining != BigInt.zero) {
      throw const FormatException('LAN pairing integer is too large');
    }
    return output;
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  static String _canonical(List<Object?> values) => jsonEncode(values);
}
