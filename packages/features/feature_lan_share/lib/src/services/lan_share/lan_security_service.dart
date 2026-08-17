// v1 LAN TLS、配对 PIN、E2E 密钥与可信对端安全服务。
//
// 配对缓存持久化位于 lan_security_pairing.dart，使本安全边界便于审计，
// 并保持在 1000 行限制以内。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:basic_utils/basic_utils.dart' hide Mac;

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

part 'lan_security_pairing.dart';
part 'lan_security_trust.dart';

/// 在工作 isolate 中生成自签名证书和私钥。
Map<String, String> _generateSelfSignedCertIsolate(String commonName) {
  final pair = CryptoUtils.generateEcKeyPair();
  final privKey = pair.privateKey as ECPrivateKey;
  final pubKey = pair.publicKey as ECPublicKey;

  final dn = {'CN': commonName, 'O': 'SSH Mobile LAN Share'};
  final csr = X509Utils.generateEccCsrPem(dn, privKey, pubKey);
  final certPem = X509Utils.generateSelfSignedCertificate(privKey, csr, 3650);
  final keyPem = CryptoUtils.encodeEcPrivateKeyToPem(privKey);

  return {'cert': certPem, 'key': keyPem};
}

/// 为定向单元测试同步生成证书材料。
@visibleForTesting
Map<String, String> generateSelfSignedCertForTest(String commonName) =>
    _generateSelfSignedCertIsolate(commonName);

/// 负责 TLS 证书生成、PIN 校验、ECDH 密钥协商和可信设备存储的服务。
class LanSecurityService {
  static const String _certKeyPrefix = 'lan_share_cert_';
  static const String _privateKeyPrefix = 'lan_share_key_';
  static const String _trustedDevicesStorageKey =
      'lan_share_trusted_fingerprints';
  static const String _peerX25519KeysStorageKey =
      'lan_share_peer_x25519_keys_v1';
  static const String _peerNetworkIdentityKeysStorageKey =
      'lan_share_peer_network_identity_keys_v1';

  final FlutterSecureStorage _secureStorage;
  final Map<String, DateTime> _lastCheckTime = {};
  static const Duration _freshOutboundPinProofTtl = Duration(seconds: 60);
  final Map<String, DateTime> _freshOutboundPinProofExpiry = {};

  /// 已配对设备状态的内存缓存。
  /// null 表示尚未从磁盘加载，首次读取时填充。
  /// key 为 deviceId，value 为时间戳（0 表示永久，>0 表示临时 epoch 毫秒）。
  Map<String, int>? _pairedCache;

  String? _cachedCertPem;
  String? _cachedKeyPem;
  SecurityContext? _cachedSecurityContext;

  String? _activePin;
  DateTime? _pinGeneratedTime;
  String? _previousPin;
  DateTime? _previousPinGeneratedTime;
  int _failedPinAttempts = 0;
  DateTime? _lockoutUntil;

  /// 创建使用平台安全存储的安全服务。
  LanSecurityService({FlutterSecureStorage? secureStorage})
    : _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  // ── E2E 应用层加密 ─────────────────────────────────────────────────────

  /// 返回本设备是否支持 E2E 应用层加密。
  static const bool supportsE2EEncryption = true;

  /// 使用 X25519 ECDH 密钥协商与 AES-256-GCM 加密 [plaintext] 字节。
  ///
  /// 返回单个数据块：[32 字节临时公钥] [12 字节 nonce] [N 字节密文+tag]。
  ///
  /// 接收方使用自己的 X25519 私钥和发送方临时公钥派生相同共享秘密并解密。
  Future<Uint8List> encryptE2E(Uint8List plaintext) async {
    final x25519 = X25519();
    final aesGcm = AesGcm.with256bits();

    // 生成发送方临时密钥对。
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();

    // 获取持久接收方公钥（服务端解密时是本机公钥；发送方需要通过请求头交换
    // 接收方公钥）。不同设备分别拥有两端密钥，因此使用本设备静态 X25519 密钥
    // 作为“接收方密钥”派生 sharedSecret。
    final staticKeyPair = await _getOrCreateStaticX25519KeyPair();
    final staticPubKey = await staticKeyPair.extractPublicKey();

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: staticPubKey,
    );

    final secretKey = SecretKey(await sharedSecret.extractBytes());
    final nonce = aesGcm.newNonce();
    final secretBox = await aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // 组合：[32B 临时公钥] + [12B nonce] + [密文 + 16B tag]。
    final ephemeralPubBytes = ephemeralPubKey.bytes;
    final ciphertextWithTag = secretBox.cipherText + secretBox.mac.bytes;
    final result = Uint8List(
      ephemeralPubBytes.length + nonce.length + ciphertextWithTag.length,
    );
    result.setRange(0, ephemeralPubBytes.length, ephemeralPubBytes);
    result.setRange(
      ephemeralPubBytes.length,
      ephemeralPubBytes.length + nonce.length,
      nonce,
    );
    result.setRange(
      ephemeralPubBytes.length + nonce.length,
      result.length,
      ciphertextWithTag,
    );
    return result;
  }

  /// 使用目标 [recipientPubKeyBytes]（X25519 公钥）加密 [plaintext] 字节。
  ///
  /// 返回与 [encryptE2E] 相同的数据块格式：[32 字节临时公钥] [12 字节 nonce]
  /// [密文+tag]。
  Future<Uint8List> encryptE2EFor(
    Uint8List plaintext,
    Uint8List recipientPubKeyBytes,
  ) async {
    final x25519 = X25519();
    final aesGcm = AesGcm.with256bits();

    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();
    final recipientPubKey = SimplePublicKey(
      recipientPubKeyBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPubKey,
    );

    final secretKey = SecretKey(await sharedSecret.extractBytes());
    final nonce = aesGcm.newNonce();
    final secretBox = await aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    final ephemeralPubBytes = ephemeralPubKey.bytes;
    final ciphertextWithTag = secretBox.cipherText + secretBox.mac.bytes;
    final result = Uint8List(
      ephemeralPubBytes.length + nonce.length + ciphertextWithTag.length,
    );
    result.setRange(0, ephemeralPubBytes.length, ephemeralPubBytes);
    result.setRange(
      ephemeralPubBytes.length,
      ephemeralPubBytes.length + nonce.length,
      nonce,
    );
    result.setRange(
      ephemeralPubBytes.length + nonce.length,
      result.length,
      ciphertextWithTag,
    );
    return result;
  }

  /// 使用本设备静态 X25519 私钥解密 [encryptE2EFor] 产生的数据块。
  Future<Uint8List> decryptE2E(Uint8List blob) async {
    const ephemeralPubLen = 32;
    const nonceLen = 12;
    const macLen = 16;

    if (blob.length < ephemeralPubLen + nonceLen + macLen) {
      throw ArgumentError('E2E blob too short');
    }

    final ephemeralPubBytes = blob.sublist(0, ephemeralPubLen);
    final nonce = blob.sublist(ephemeralPubLen, ephemeralPubLen + nonceLen);
    final ciphertextWithTag = blob.sublist(ephemeralPubLen + nonceLen);

    final ciphertext = ciphertextWithTag.sublist(
      0,
      ciphertextWithTag.length - macLen,
    );
    final mac = Mac(
      ciphertextWithTag.sublist(ciphertextWithTag.length - macLen),
    );

    final x25519 = X25519();
    final aesGcm = AesGcm.with256bits();

    final staticKeyPair = await _getOrCreateStaticX25519KeyPair();
    final ephemeralPubKey = SimplePublicKey(
      ephemeralPubBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: staticKeyPair,
      remotePublicKey: ephemeralPubKey,
    );

    final secretKey = SecretKey(await sharedSecret.extractBytes());
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);
    final plaintext = await aesGcm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(plaintext);
  }

  /// 返回本设备持久化 X25519 公钥字节（32 字节）。
  Future<Uint8List> getStaticX25519PublicKeyBytes() async {
    final kp = await _getOrCreateStaticX25519KeyPair();
    final pub = await kp.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// 返回交给进程内原生网络运行时的持久化 X25519 种子。
  /// 调用方必须仅在内存中保存它。
  Future<Uint8List> getStaticX25519PrivateKeyBytes() async {
    final keyPair = await _getOrCreateStaticX25519KeyPair();
    return Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
  }

  /// 保存已认证配对通道中观察到的 E2E 密钥。
  /// 公开 Relay 传输会拒绝没有该固定密钥的对端，因此缺少密钥的配对必须刷新，
  /// 不能降级为明文。
  Future<void> storePeerX25519PublicKey(
    String deviceId,
    Uint8List publicKey,
  ) async {
    if (deviceId.isEmpty ||
        publicKey.length != 32 ||
        !await isDevicePaired(deviceId)) {
      throw ArgumentError(
        'A paired device and a 32-byte public key are required.',
      );
    }
    final values = await _readPeerX25519Keys();
    final encoded = base64UrlEncode(publicKey).replaceAll('=', '');
    final existing = values[deviceId];
    if (existing != null && existing != encoded) {
      throw StateError(
        'LAN peer X25519 key changed; unpair before pairing again.',
      );
    }
    values[deviceId] = encoded;
    await _secureStorage.write(
      key: _peerX25519KeysStorageKey,
      value: jsonEncode(values),
    );
  }

  /// 返回已配对设备固定的 X25519 公钥（若存在）。
  Future<Uint8List?> getPeerX25519PublicKey(String deviceId) async {
    if (!await isDevicePaired(deviceId)) return null;
    final value = (await _readPeerX25519Keys())[deviceId];
    if (value == null) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      return bytes.length == 32 ? Uint8List.fromList(bytes) : null;
    } catch (_) {
      return null;
    }
  }

  /// 从安全存储读取设备到 X25519 密钥的映射。
  Future<Map<String, String>> _readPeerX25519Keys() async {
    final raw = await _secureStorage.read(key: _peerX25519KeysStorageKey);
    if (raw == null) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, String>{};
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (_) {
      return <String, String>{};
    }
  }

  /// 移除设备固定的 X25519 公钥。
  Future<void> _removePeerX25519PublicKey(String deviceId) async {
    final values = await _readPeerX25519Keys();
    if (values.remove(deviceId) != null) {
      await _secureStorage.write(
        key: _peerX25519KeysStorageKey,
        value: jsonEncode(values),
      );
    }
  }

  /// 保存原生 QUIC 握手使用的 Ed25519 身份。
  /// 密钥固定在配对记录中，直到解除配对前不得轮换。
  Future<void> storePeerNetworkIdentityPublicKey(
    String deviceId,
    Uint8List publicKey,
  ) async {
    if (deviceId.isEmpty ||
        publicKey.length != 32 ||
        !await isDevicePaired(deviceId)) {
      throw ArgumentError(
        'A paired device and a 32-byte network identity key are required.',
      );
    }
    final values = await _readPeerNetworkIdentityKeys();
    final encoded = base64UrlEncode(publicKey).replaceAll('=', '');
    final existing = values[deviceId];
    if (existing != null && existing != encoded) {
      throw StateError(
        'LAN peer network identity changed; unpair before pairing again.',
      );
    }
    values[deviceId] = encoded;
    await _secureStorage.write(
      key: _peerNetworkIdentityKeysStorageKey,
      value: jsonEncode(values),
    );
  }

  /// 返回已配对设备固定的原生网络身份密钥。
  Future<Uint8List?> getPeerNetworkIdentityPublicKey(String deviceId) async {
    if (!await isDevicePaired(deviceId)) return null;
    final value = (await _readPeerNetworkIdentityKeys())[deviceId];
    if (value == null) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      return bytes.length == 32 ? Uint8List.fromList(bytes) : null;
    } catch (_) {
      return null;
    }
  }

  /// 从安全存储读取设备到网络身份密钥的映射。
  Future<Map<String, String>> _readPeerNetworkIdentityKeys() async {
    final raw = await _secureStorage.read(
      key: _peerNetworkIdentityKeysStorageKey,
    );
    if (raw == null) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, String>{};
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (_) {
      return <String, String>{};
    }
  }

  /// 移除设备固定的原生网络身份密钥。
  Future<void> _removePeerNetworkIdentityPublicKey(String deviceId) async {
    final values = await _readPeerNetworkIdentityKeys();
    if (values.remove(deviceId) != null) {
      await _secureStorage.write(
        key: _peerNetworkIdentityKeysStorageKey,
        value: jsonEncode(values),
      );
    }
  }

  static const String _x25519PrivKeyStorageKey = 'lan_share_x25519_priv';
  SimpleKeyPair? _cachedX25519KeyPair;

  /// 加载或创建本设备持久化 X25519 密钥对。
  Future<SimpleKeyPair> _getOrCreateStaticX25519KeyPair() async {
    if (_cachedX25519KeyPair != null) return _cachedX25519KeyPair!;

    final x25519 = X25519();
    final stored = await _secureStorage.read(key: _x25519PrivKeyStorageKey);
    if (stored != null) {
      final privBytes = base64.decode(stored);
      _cachedX25519KeyPair = await x25519.newKeyPairFromSeed(privBytes);
    } else {
      final kp = await x25519.newKeyPair();
      final privBytes = await kp.extractPrivateKeyBytes();
      await _secureStorage.write(
        key: _x25519PrivKeyStorageKey,
        value: base64.encode(privBytes),
      );
      _cachedX25519KeyPair = kp;
    }
    return _cachedX25519KeyPair!;
  }

  /// 生成或加载持久化 ECDSA 自签名 TLS 证书。
  Future<SecurityContext> getOrCreateSecurityContext(String deviceId) async {
    if (_cachedSecurityContext != null) {
      return _cachedSecurityContext!;
    }

    final certKey = '$_certKeyPrefix$deviceId';
    final privateKeyKey = '$_privateKeyPrefix$deviceId';

    _cachedCertPem = await _secureStorage.read(key: certKey);
    _cachedKeyPem = await _secureStorage.read(key: privateKeyKey);

    if (_cachedCertPem == null || _cachedKeyPem == null) {
      debugPrint(
        '[LanSecurityService] Generating new self-signed TLS certificate in Isolate...',
      );
      // 在单测环境下，headless flutter_tester 中的 compute() 可能因 Isolate channel 未初始化而永久挂起；
      // EC 密钥生成耗时极短（约 10-20ms），直接同步生成保证单测与 CI 稳定。
      final certData = _generateSelfSignedCertIsolate('device-$deviceId');
      _cachedCertPem = certData['cert']!;
      _cachedKeyPem = certData['key']!;

      await _secureStorage.write(key: certKey, value: _cachedCertPem);
      await _secureStorage.write(key: privateKeyKey, value: _cachedKeyPem);
    }

    final context = SecurityContext(withTrustedRoots: false);
    final certBytes = utf8.encode(_cachedCertPem!);
    final keyBytes = utf8.encode(_cachedKeyPem!);

    context.useCertificateChainBytes(certBytes);
    context.usePrivateKeyBytes(keyBytes);

    _cachedSecurityContext = context;
    return context;
  }

  /// 计算 PEM 证书的 SHA-256 指纹。
  Future<String> computeCertFingerprint(String certPem) async {
    final lines = certPem
        .split('\n')
        .where((line) => !line.startsWith('---'))
        .join('')
        .replaceAll('\r', '')
        .replaceAll('\n', '');
    final bytes = base64.decode(lines);
    final digest = await Sha256().hash(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 生成设备配对使用的随机六位 PIN。
  String generate6DigitPin() {
    final random = Random.secure();
    final pin = (100000 + random.nextInt(900000)).toString();

    // 保留旧的活动 PIN，用于宽限期校验。
    _previousPin = _activePin;
    _previousPinGeneratedTime = _pinGeneratedTime;

    _activePin = pin;
    _pinGeneratedTime = DateTime.now();
    _failedPinAttempts = 0;
    _lockoutUntil = null;
    debugPrint('[LanSecurityService] Generated a new pairing PIN');
    return pin;
  }

  /// 在活动配对 PIN 有效期间返回它。
  String? get activePin {
    if (_activePin == null || _pinGeneratedTime == null) return null;
    final diff = DateTime.now().difference(_pinGeneratedTime!);
    if (diff.inSeconds > 60) {
      _activePin = null;
      _pinGeneratedTime = null;
      return null;
    }
    return _activePin;
  }

  /// 返回活动配对 PIN 的剩余有效秒数。
  int get pinSecondsRemaining {
    if (_activePin == null || _pinGeneratedTime == null) return 0;
    final diff = DateTime.now().difference(_pinGeneratedTime!);
    final remaining = 60 - diff.inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  /// 复用活动 PIN，或生成新的六位配对 PIN。
  String getOrGenerate6DigitPin() {
    final current = activePin;
    if (current != null) return current;
    return generate6DigitPin();
  }

  /// 在带锁定保护的前提下校验传入 PIN。
  bool verifyPin(String candidatePin) {
    debugPrint('[LanSecurityService] Verifying pairing PIN');
    if (_lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!)) {
      debugPrint(
        '[LanSecurityService] PIN verification locked out until $_lockoutUntil',
      );
      return false;
    }

    final currentPin = activePin;

    // 1. 与当前活动 PIN 校验。
    if (currentPin != null && candidatePin == currentPin) {
      debugPrint(
        '[LanSecurityService] PIN verified successfully (current PIN match)',
      );
      _failedPinAttempts = 0;
      return true;
    }

    // 2. 与旧 PIN 校验，并提供 15 秒宽限期（从旧 PIN 生成起总计 75 秒）。
    if (_previousPin != null && _previousPinGeneratedTime != null) {
      final diff = DateTime.now().difference(_previousPinGeneratedTime!);
      debugPrint(
        '[LanSecurityService] Checking previous PIN grace. Elapsed seconds since previous generation: ${diff.inSeconds}s',
      );
      if (diff.inSeconds <= 75 && candidatePin == _previousPin) {
        debugPrint(
          '[LanSecurityService] PIN verified successfully (previous PIN match via grace period)',
        );
        _failedPinAttempts = 0;
        return true;
      }
    }

    _failedPinAttempts++;
    debugPrint(
      '[LanSecurityService] PIN mismatch! Failed attempts: $_failedPinAttempts',
    );
    if (_failedPinAttempts >= 3) {
      _lockoutUntil = DateTime.now().add(const Duration(seconds: 30));
      debugPrint(
        '[LanSecurityService] PIN failed 3 times. Locked out for 30s.',
      );
    }
    return false;
  }

  /// 报告配对认证当前是否被锁定。
  bool get isLockedOut =>
      _lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!);

  /// 返回 SRP-6a 交换使用的当前轮换 PIN 候选。
  /// 每个候选拥有独立 salt 和指数。
  List<String> validPairingPinsForHandshake() {
    if (isLockedOut) return const [];
    final pins = <String>[];
    final current = activePin;
    if (current != null) pins.add(current);
    if (_previousPin != null && _previousPinGeneratedTime != null) {
      final age = DateTime.now().difference(_previousPinGeneratedTime!);
      if (age.inSeconds <= 75 && !pins.contains(_previousPin)) {
        pins.add(_previousPin!);
      }
    }
    return List.unmodifiable(pins);
  }

  /// 清除配对认证失败次数和锁定计数。
  void recordPairingAuthenticationSuccess() {
    _failedPinAttempts = 0;
    _lockoutUntil = null;
  }

  /// 记录一次配对认证失败，并应用锁定策略。
  void recordPairingAuthenticationFailure() {
    _failedPinAttempts++;
    if (_failedPinAttempts >= 3) {
      _lockoutUntil = DateTime.now().add(const Duration(seconds: 30));
    }
  }

  static const String _pairedDevicesStorageKey = 'lan_share_paired_device_ids';
  static const String _inboundAccessTokensStorageKey =
      'lan_share_inbound_access_tokens';
  static const String _outboundAccessTokensStorageKey =
      'lan_share_outbound_access_tokens';
  static const String _peerCertificateFingerprintsStorageKey =
      'lan_share_peer_certificate_fingerprints';

  Map<String, String>? _inboundAccessTokenCache;
  Map<String, String>? _outboundAccessTokenCache;

  /// 读取安全存储映射；数据无效时返回空映射。
  Future<Map<String, String>> _readAccessTokenMap(String storageKey) async {
    final raw = await _secureStorage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return decoded.map((key, value) => MapEntry(key, value as String));
    } catch (_) {
      return {};
    }
  }

  /// 加载并缓存本设备接受的 token。
  Future<Map<String, String>> _loadInboundAccessTokens() async {
    return _inboundAccessTokenCache ??= await _readAccessTokenMap(
      _inboundAccessTokensStorageKey,
    );
  }

  /// 加载并缓存发给远端设备的 token。
  Future<Map<String, String>> _loadOutboundAccessTokens() async {
    return _outboundAccessTokenCache ??= await _readAccessTokenMap(
      _outboundAccessTokensStorageKey,
    );
  }

  /// 签发或复用一个已配对设备接受的 token。
  Future<String> issueInboundAccessToken(String deviceId) async {
    if (deviceId.isEmpty || deviceId.length > 128) {
      throw ArgumentError('Invalid LAN pairing device ID.');
    }
    final tokens = await _loadInboundAccessTokens();
    final existing = tokens[deviceId];
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final token = base64Url.encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    tokens[deviceId] = token;
    await _secureStorage.write(
      key: _inboundAccessTokensStorageKey,
      value: jsonEncode(tokens),
    );
    return token;
  }

  /// 保存已配对远端设备签发的 token。
  Future<void> storeOutboundAccessToken(String deviceId, String token) async {
    if (deviceId.isEmpty || token.isEmpty || token.length > 256) {
      throw ArgumentError('Invalid LAN pairing access token.');
    }
    final tokens = await _loadOutboundAccessTokens();
    tokens[deviceId] = token;
    await _secureStorage.write(
      key: _outboundAccessTokensStorageKey,
      value: jsonEncode(tokens),
    );
  }

  /// 返回发给已配对远端设备的 token（若存在）。
  Future<String?> getOutboundAccessToken(String deviceId) async {
    final tokens = await _loadOutboundAccessTokens();
    return tokens[deviceId];
  }

  /// 记录本进程刚刚验证了对端 PIN，并持久化了对端返回的凭据。
  /// 该证明特意只保存在内存且有效期很短：旧的单向尝试遗留 token 不得单独满足
  /// 后续相互配对校验。
  void markFreshOutboundPairProof({
    required String deviceId,
    required String peerFingerprint,
    required String localFingerprint,
    required String accessToken,
  }) {
    final proofKey = _freshOutboundProofKey(
      deviceId: deviceId,
      peerFingerprint: peerFingerprint,
      localFingerprint: localFingerprint,
      accessToken: accessToken,
    );
    _pruneFreshOutboundPinProofs();
    _freshOutboundPinProofExpiry[proofKey] = DateTime.now().add(
      _freshOutboundPinProofTtl,
    );
  }

  /// 报告当前绑定条件下是否存在未过期的出站配对证明。
  @visibleForTesting
  bool hasFreshOutboundPairProof({
    required String deviceId,
    required String peerFingerprint,
    required String localFingerprint,
    required String accessToken,
  }) {
    _pruneFreshOutboundPinProofs();
    final proofKey = _freshOutboundProofKey(
      deviceId: deviceId,
      peerFingerprint: peerFingerprint,
      localFingerprint: localFingerprint,
      accessToken: accessToken,
    );
    final expiresAt = _freshOutboundPinProofExpiry[proofKey];
    return expiresAt != null && DateTime.now().isBefore(expiresAt);
  }

  /// 恰好消费一次与远端、证书和 token 绑定的短期出站配对证明。
  Future<bool> consumeFreshOutboundPinProof({
    required String deviceId,
    required String peerFingerprint,
    required String localFingerprint,
  }) async {
    _pruneFreshOutboundPinProofs();
    final storedFingerprint = await getPeerCertificateFingerprint(deviceId);
    final accessToken = await getOutboundAccessToken(deviceId);
    if (storedFingerprint == null ||
        storedFingerprint.toLowerCase() != peerFingerprint.toLowerCase() ||
        accessToken == null ||
        accessToken.isEmpty) {
      return false;
    }
    final proofKey = _freshOutboundProofKey(
      deviceId: deviceId,
      peerFingerprint: peerFingerprint,
      localFingerprint: localFingerprint,
      accessToken: accessToken,
    );
    final expiresAt = _freshOutboundPinProofExpiry.remove(proofKey);
    return expiresAt != null && DateTime.now().isBefore(expiresAt);
  }

  /// 构建一个新的出站配对证明绑定 key。
  String _freshOutboundProofKey({
    required String deviceId,
    required String peerFingerprint,
    required String localFingerprint,
    required String accessToken,
  }) {
    if (deviceId.isEmpty ||
        deviceId.length > 128 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(peerFingerprint) ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(localFingerprint) ||
        accessToken.isEmpty ||
        accessToken.length > 256) {
      throw ArgumentError('Invalid LAN outbound pairing proof binding.');
    }
    final tokenHash = crypto.sha256.convert(utf8.encode(accessToken));
    return '$deviceId\u0000${peerFingerprint.toLowerCase()}\u0000'
        '${localFingerprint.toLowerCase()}\u0000$tokenHash';
  }

  /// 报告设备是否同时拥有出站 token 和证书数据。
  Future<bool> hasCompleteOutboundPairCredential(String deviceId) async {
    final token = await getOutboundAccessToken(deviceId);
    if (token == null || token.isEmpty) return false;
    return hasPeerCertificateFingerprint(deviceId);
  }

  /// 移除过期的内存出站配对证明。
  void _pruneFreshOutboundPinProofs() {
    final now = DateTime.now();
    _freshOutboundPinProofExpiry.removeWhere(
      (_, expiresAt) => !now.isBefore(expiresAt),
    );
  }

  /// 使用恒定时间逐字节校验比较传入 token。
  Future<bool> verifyInboundAccessToken(String deviceId, String token) async {
    final tokens = await _loadInboundAccessTokens();
    final expected = tokens[deviceId];
    if (expected == null || expected.length != token.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// 报告 [deviceId] 是否有可用出站访问 token。
  Future<bool> hasOutboundAccessToken(String deviceId) async {
    final token = await getOutboundAccessToken(deviceId);
    return token != null && token.isNotEmpty;
  }

  /// 从安全存储加载设备到证书指纹的映射。
  Future<Map<String, String>> _loadPeerCertificateFingerprints() async {
    final raw = await _secureStorage.read(
      key: _peerCertificateFingerprintsStorageKey,
    );
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return decoded.map((key, value) => MapEntry(key, value as String));
    } catch (_) {
      return {};
    }
  }

  /// 保存证书指纹，并拒绝静默密钥轮换。
  Future<void> storePeerCertificateFingerprint(
    String deviceId,
    String fingerprint,
  ) async {
    if (deviceId.isEmpty ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fingerprint)) {
      throw ArgumentError('Invalid LAN peer certificate fingerprint.');
    }
    final fingerprints = await _loadPeerCertificateFingerprints();
    final normalizedFingerprint = fingerprint.toLowerCase();
    final existing = fingerprints[deviceId]?.toLowerCase();
    if (existing != null && existing != normalizedFingerprint) {
      throw StateError(
        'LAN peer certificate changed; unpair the device before re-pairing.',
      );
    }
    fingerprints[deviceId] = normalizedFingerprint;
    await _secureStorage.write(
      key: _peerCertificateFingerprintsStorageKey,
      value: jsonEncode(fingerprints),
    );
  }

  /// 返回已配对设备固定的证书指纹。
  Future<String?> getPeerCertificateFingerprint(String deviceId) async {
    final fingerprints = await _loadPeerCertificateFingerprints();
    return fingerprints[deviceId];
  }

  /// 报告 [deviceId] 是否已固定证书指纹。
  Future<bool> hasPeerCertificateFingerprint(String deviceId) async {
    final fingerprint = await getPeerCertificateFingerprint(deviceId);
    return fingerprint != null && fingerprint.isNotEmpty;
  }

  /// 移除一个设备的访问 token、指纹和证明。
  Future<void> _removePairAccessTokens(String deviceId) async {
    final inbound = await _loadInboundAccessTokens();
    final outbound = await _loadOutboundAccessTokens();
    final fingerprints = await _loadPeerCertificateFingerprints();
    final removedInbound = inbound.remove(deviceId) != null;
    final removedOutbound = outbound.remove(deviceId) != null;
    final removedFingerprint = fingerprints.remove(deviceId) != null;
    _freshOutboundPinProofExpiry.removeWhere(
      (key, _) => key.startsWith('$deviceId\u0000'),
    );
    if (removedInbound) {
      await _secureStorage.write(
        key: _inboundAccessTokensStorageKey,
        value: jsonEncode(inbound),
      );
    }
    if (removedOutbound) {
      await _secureStorage.write(
        key: _outboundAccessTokensStorageKey,
        value: jsonEncode(outbound),
      );
    }
    if (removedFingerprint) {
      await _secureStorage.write(
        key: _peerCertificateFingerprintsStorageKey,
        value: jsonEncode(fingerprints),
      );
    }
  }

  /// 检查远端设备是否已配对，并按需重新验证。
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async {
    // 1. 缓存尚未加载时只从磁盘读取一次。
    if (_pairedCache == null) {
      await _loadPairedCacheFromDisk();
    }

    final cache = _pairedCache!;

    if (!cache.containsKey(deviceId) ||
        !await hasOutboundAccessToken(deviceId) ||
        !await hasPeerCertificateFingerprint(deviceId)) {
      return false;
    }

    final timestamp = cache[deviceId]!;
    // timestamp == 0 表示永久配对（双向确认）。
    if (timestamp == 0) {
      return true;
    }

    // 临时配对：检查一分钟有效期。
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - timestamp > 60000) {
      cache.remove(deviceId);
      // 异步持久化移除结果，避免阻塞当前调用。
      unawaited(
        _secureStorage.write(
          key: _pairedDevicesStorageKey,
          value: jsonEncode(cache),
        ),
      );
      return false;
    }

    // 启动后台远端验证，将临时配对升级为永久配对。
    if (ip != null && port != null && localDeviceId != null) {
      final lastCheck = _lastCheckTime[deviceId];
      if (lastCheck == null ||
          DateTime.now().difference(lastCheck).inSeconds > 5) {
        _lastCheckTime[deviceId] = DateTime.now();

        unawaited(() async {
          try {
            final expectedFingerprint = await getPeerCertificateFingerprint(
              deviceId,
            );
            final client = HttpClient(context: SecurityContext())
              ..findProxy = ((_) => 'DIRECT')
              ..badCertificateCallback = (cert, host, port) {
                if (expectedFingerprint == null) return false;
                return _certificateFingerprintFromDer(cert.der) ==
                    expectedFingerprint;
              };
            final url = Uri.parse(
              'https://$ip:$port/api/lan/check_pair?deviceId=$localDeviceId',
            );
            final request = await client
                .getUrl(url)
                .timeout(const Duration(seconds: 2));
            final token = await getOutboundAccessToken(deviceId);
            if (token == null || token.isEmpty) {
              client.close();
              return;
            }
            request.headers.set('x-device-id', localDeviceId);
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer $token',
            );
            final response = await request.close().timeout(
              const Duration(seconds: 2),
            );
            if (response.statusCode == HttpStatus.ok) {
              final body = await utf8.decoder.bind(response).join();
              final json = jsonDecode(body) as Map<String, dynamic>;
              if (json['paired'] == true) {
                // 在缓存和磁盘中都升级为永久配对。
                cache[deviceId] = 0;
                await _secureStorage.write(
                  key: _pairedDevicesStorageKey,
                  value: jsonEncode(cache),
                );
              }
            }
            client.close();
          } catch (e) {
            debugPrint('[LanSecurityService] Failed to check remote pair: $e');
          }
        }());
      }
    }

    return true;
  }

  /// 移除远端设备及绑定到该设备的全部凭据。
  Future<void> unpairDevice(String deviceId) async {
    if (_pairedCache == null) await _loadPairedCacheFromDisk();
    final cache = _pairedCache!;
    cache.remove(deviceId);
    _freshOutboundPinProofExpiry.remove(deviceId);
    await _secureStorage.write(
      key: _pairedDevicesStorageKey,
      value: jsonEncode(cache),
    );
    await _removePairAccessTokens(deviceId);
    await _removePeerX25519PublicKey(deviceId);
    await _removePeerNetworkIdentityPublicKey(deviceId);
  }

  /// 计算 TLS 回调使用的同步证书指纹。
  static String _certificateFingerprintFromDer(Uint8List der) {
    // 保持回调同步；协议使用与 computeCertFingerprint() 相同的 SHA-256 表示。
    return crypto.sha256.convert(der).toString();
  }
}
