// LAN Control Protocol V2 配对密码学：PIN 证明、SRP 材料与凭据校验辅助逻辑。
// 本文件不承载传输或 UI 策略。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:pointycastle/srp/srp6_client.dart' as pc;
import 'package:pointycastle/srp/srp6_server.dart' as pc;
import 'package:pointycastle/srp/srp6_standard_groups.dart' as pc;
import 'package:pointycastle/srp/srp6_verifier_generator.dart' as pc;

/// 一次性 SRP-6a 状态，不得用于另一个邀请。
class LanPairingEphemeralKeyPair {
  final Object engine;
  final Uint8List salt;
  final Uint8List publicValue;
  final bool isClient;
  final int slot;
  final BigInt? sharedSecret;

  /// 为配对邀请创建一次性 SRP 状态。
  const LanPairingEphemeralKeyPair({
    required this.engine,
    required this.salt,
    required this.publicValue,
    required this.isClient,
    required this.slot,
    this.sharedSecret,
  });
}

/// 两端 SRP 派生共享秘密后生成的 transcript 绑定密钥。
class LanPairingSessionSecrets {
  final Uint8List sessionKey;
  final Uint8List clientConfirmationKey;
  final Uint8List serverConfirmationKey;
  final Uint8List transcript;

  /// 创建 transcript 绑定的会话密钥。
  const LanPairingSessionSecrets({
    required this.sessionKey,
    required this.clientConfirmationKey,
    required this.serverConfirmationKey,
    required this.transcript,
  });
}

/// RFC 5054 SRP-6a 与 transcript 绑定的双向密钥确认。
///
/// 本地固定使用 3072 位群组。每个轮换 PIN 槽位使用不同 salt 和独立 SRP 指数，
/// 因此捕获的交换数据不会暴露离线 PIN 校验器，也不能跨槽位反射。
class LanPairingCrypto {
  static const int protocolVersion = 2;
  static const int publicValueBytes = 384;
  static const int maxServerOffers = 2;
  static const int credentialTtlMillis = 15000;
  static const String _domainLabel = 'ssh-mobile-lan-pair';
  static const String suite = 'srp6a-rfc5054-3072-sha256-hkdf-hmac';

  static final pc.SRP6GroupParameters _group =
      pc.SRP6StandardGroups.rfc5054_3072;
  static final Random _secureRandom = Random.secure();

  /// 为一个 PIN 槽位生成客户端 SRP 凭据。
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

  /// 生成服务端 SRP 凭据并计算共享秘密。
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

  /// 根据双方 SRP 材料派生会话密钥和确认密钥。
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

  /// 创建 transcript 绑定密钥确认所需的客户端证明。
  static String createClientProof(LanPairingSessionSecrets secrets) =>
      _createProof(secrets.clientConfirmationKey, secrets.transcript);

  /// 创建 transcript 绑定密钥确认所需的服务端证明。
  static String createServerProof(LanPairingSessionSecrets secrets) =>
      _createProof(secrets.serverConfirmationKey, secrets.transcript);

  /// 使用派生的会话密钥校验客户端证明。
  static bool verifyClientProof(
    LanPairingSessionSecrets secrets,
    String proof,
  ) => _verifyProof(secrets.clientConfirmationKey, secrets.transcript, proof);

  /// 使用派生的会话密钥校验服务端证明。
  static bool verifyServerProof(
    LanPairingSessionSecrets secrets,
    String proof,
  ) => _verifyProof(secrets.serverConfirmationKey, secrets.transcript, proof);

  /// 生成 URL 安全的随机配对令牌。
  static String randomToken({int byteLength = 24}) {
    final bytes = List<int>.generate(
      byteLength,
      (_) => _secureRandom.nextInt(256),
      growable: false,
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 使用 AES-GCM 和关联数据加密配对凭据。
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

  /// 解密并校验 AES-GCM 配对凭据。
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

  /// 构建规范化客户端上下文 transcript。
  static String clientContext({
    required String senderDeviceId,
    required String targetDeviceId,
    required String nonce,
    required String alias,
    required String os,
    required int port,
    required bool isInitiator,
    required String senderCertFingerprint,
    required Uint8List senderX25519PublicKey,
    required Uint8List senderNetworkIdentityPublicKey,
    required String senderInboundAccessTokenHash,
  }) {
    _validatePublicKey(senderX25519PublicKey, 'sender X25519 public key');
    _validatePublicKey(
      senderNetworkIdentityPublicKey,
      'sender network identity public key',
    );
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(senderInboundAccessTokenHash)) {
      throw const FormatException('Invalid sender access-token binding.');
    }
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
      base64UrlEncode(senderX25519PublicKey),
      base64UrlEncode(senderNetworkIdentityPublicKey),
      senderInboundAccessTokenHash,
    ]);
  }

  /// 构建规范化 SRP 会话关联数据 transcript。
  static String sessionAssociatedData({
    required String clientContext,
    required String handshakeId,
    required int slot,
    required Uint8List salt,
    required Uint8List clientPublicValue,
    required Uint8List serverPublicValue,
    required String serverCertFingerprint,
    required Uint8List serverX25519PublicKey,
    required Uint8List serverNetworkIdentityPublicKey,
  }) {
    _validatePublicKey(serverX25519PublicKey, 'server X25519 public key');
    _validatePublicKey(
      serverNetworkIdentityPublicKey,
      'server network identity public key',
    );
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
      base64UrlEncode(serverX25519PublicKey),
      base64UrlEncode(serverNetworkIdentityPublicKey),
    ]);
  }

  /// 构建规范化凭据关联数据 transcript。
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

  /// 对客户端上下文做哈希，用于请求绑定。
  static String requestHash(String clientContext) =>
      crypto.sha256.convert(utf8.encode(clientContext)).toString();

  /// Hash a one-time inbound bearer token without exposing the token in the
  /// unauthenticated begin request.  The hash is part of the SRP transcript;
  /// the clear token is only accepted inside the authenticated confirm.
  static String accessTokenHash(String token) {
    if (token.isEmpty || token.length > 256) {
      throw const FormatException('Invalid LAN access token.');
    }
    return crypto.sha256.convert(utf8.encode(token)).toString();
  }

  /// Constant-time comparison for an access-token hash.
  static bool verifyAccessTokenHash(String token, String expectedHash) {
    try {
      final actual = accessTokenHash(token);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash)) return false;
      var difference = 0;
      for (var index = 0; index < actual.length; index++) {
        difference |= actual.codeUnitAt(index) ^ expectedHash.codeUnitAt(index);
      }
      return difference == 0;
    } catch (_) {
      return false;
    }
  }

  /// Decode and validate one of the fixed-size static peer public keys.
  static Uint8List decodePublicKey(String encoded, String label) {
    try {
      final bytes = base64Url.decode(base64Url.normalize(encoded));
      _validatePublicKey(bytes, label);
      return Uint8List.fromList(bytes);
    } catch (_) {
      throw FormatException('Invalid $label.');
    }
  }

  static void _validatePublicKey(List<int> bytes, String label) {
    if (bytes.length != 32) throw FormatException('Invalid $label.');
  }

  /// 为定向测试和协议边界校验公共 SRP 值。
  static bool isValidPublicValueForTesting(Uint8List value) {
    try {
      _decodePublicValue(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 为一个轮换 PIN 槽位派生确定性 salt。
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

  /// 将上下文转换为固定的 SRP 身份字节。
  static Uint8List _identity(String clientContext) => Uint8List.fromList(
    utf8.encode('$_domainLabel\u0000$protocolVersion\u0000$clientContext'),
  );

  /// 校验六位 PIN 与轮换槽位索引。
  static void _validatePinAndSlot(String pin, int slot) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin) ||
        slot < 0 ||
        slot >= maxServerOffers) {
      throw const FormatException('Invalid LAN pairing PIN slot');
    }
  }

  /// 返回整数是否处于有效 SRP 群组范围。
  static bool _isValidPublicInteger(BigInt value) =>
      value > BigInt.zero && value < _group.N;

  /// 解码并校验规范化定长公共 SRP 值。
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

  /// 为 SRP 创建带种子的密码学安全随机源。
  static pc.SecureRandom _newSecureRandom() {
    final random = pc.FortunaRandom();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => _secureRandom.nextInt(256)),
    );
    random.seed(pc.KeyParameter(seed));
    return random;
  }

  /// 对配对 transcript 创建 base64 HMAC 证明。
  static String _createProof(Uint8List key, Uint8List transcript) {
    return base64.encode(
      crypto.Hmac(crypto.sha256, key).convert(transcript).bytes,
    );
  }

  /// 以恒定时间校验 base64 HMAC 证明。
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

  /// 使用 HKDF-SHA256 派生有界密钥流。
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

  /// 将正整数编码为定长大端字节。
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

  /// 将大端字节解码为正整数。
  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  /// 比较两个字节数组，避免提前退出。
  static bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  /// 将协议 transcript 组件规范化编码为 JSON。
  static String _canonical(List<Object?> values) => jsonEncode(values);
}
