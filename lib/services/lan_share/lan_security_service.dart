import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:basic_utils/basic_utils.dart' hide Mac;

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Top-level function for compute() isolate execution
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

@visibleForTesting
Map<String, String> generateSelfSignedCertForTest(String commonName) =>
    _generateSelfSignedCertIsolate(commonName);

/// Service handling TLS certificate generation, PIN verification,
/// ECDH key agreement, and trusted device storage.
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

  /// In-memory cache for paired device states.
  /// null = not yet loaded from disk; populated on first read.
  /// Key: deviceId, Value: timestamp (0 = permanent, >0 = temporary epoch ms)
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

  LanSecurityService({FlutterSecureStorage? secureStorage})
    : _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  // ── E2E Application-Layer Encryption ─────────────────────────────────────

  /// This device supports E2E application-layer encryption.
  static const bool supportsE2EEncryption = true;

  /// Encrypt [plaintext] bytes using X25519 ECDH key agreement + AES-256-GCM.
  ///
  /// Returns a single blob:
  ///   [32 bytes ephemeral pubkey] [12 bytes nonce] [N bytes ciphertext+tag]
  ///
  /// The recipient uses their own X25519 private key + sender's ephemeral
  /// public key to derive the same shared secret and decrypt.
  Future<Uint8List> encryptE2E(Uint8List plaintext) async {
    final x25519 = X25519();
    final aesGcm = AesGcm.with256bits();

    // Generate ephemeral sender key pair
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();

    // Get persistent receiver public key (our own for server-side decryption;
    // for sender side we'll need the receiver's pubkey via header exchange.
    // Since we own both sides' keys on different devices, we use this device's
    // static X25519 key as the "recipient key" to derive sharedSecret.
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

    // Compose: [32B ephemeral pub] + [12B nonce] + [ciphertext + 16B tag]
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

  /// Encrypt [plaintext] bytes addressed TO [recipientPubKeyBytes] (X25519 pub).
  ///
  /// Returns same blob format as [encryptE2E]:
  ///   [32 bytes ephemeral pubkey] [12 bytes nonce] [ciphertext+tag]
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

  /// Decrypt a blob produced by [encryptE2EFor] using this device's
  /// static X25519 private key.
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

  /// Returns this device's persistent X25519 public key bytes (32 bytes).
  Future<Uint8List> getStaticX25519PublicKeyBytes() async {
    final kp = await _getOrCreateStaticX25519KeyPair();
    final pub = await kp.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// Returns the persistent X25519 seed for handoff to the in-process native
  /// network runtime. Callers must keep it memory-only.
  Future<Uint8List> getStaticX25519PrivateKeyBytes() async {
    final keyPair = await _getOrCreateStaticX25519KeyPair();
    return Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
  }

  /// Stores the E2E key observed over an already authenticated pairing channel.
  /// Public relay transfers refuse peers that do not have this pinned key, so
  /// pairings missing the key must be refreshed instead of becoming plaintext.
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

  Future<void> _removePeerX25519PublicKey(String deviceId) async {
    final values = await _readPeerX25519Keys();
    if (values.remove(deviceId) != null) {
      await _secureStorage.write(
        key: _peerX25519KeysStorageKey,
        value: jsonEncode(values),
      );
    }
  }

  /// Stores the Ed25519 identity used by the native QUIC handshake. The key is
  /// pinned to the pairing and cannot rotate until the peer is unpaired.
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

  /// Generate or load persistent ECDSA self-signed TLS certificate
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
      final certData = await compute(
        _generateSelfSignedCertIsolate,
        'device-$deviceId',
      );
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

  /// Compute SHA-256 fingerprint of a PEM certificate
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

  /// Generate a random 6-digit PIN for device pairing
  String generate6DigitPin() {
    final random = Random.secure();
    final pin = (100000 + random.nextInt(900000)).toString();

    // Preserve the old active PIN for the grace period check
    _previousPin = _activePin;
    _previousPinGeneratedTime = _pinGeneratedTime;

    _activePin = pin;
    _pinGeneratedTime = DateTime.now();
    _failedPinAttempts = 0;
    _lockoutUntil = null;
    debugPrint('[LanSecurityService] Generated a new pairing PIN');
    return pin;
  }

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

  int get pinSecondsRemaining {
    if (_activePin == null || _pinGeneratedTime == null) return 0;
    final diff = DateTime.now().difference(_pinGeneratedTime!);
    final remaining = 60 - diff.inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  String getOrGenerate6DigitPin() {
    final current = activePin;
    if (current != null) return current;
    return generate6DigitPin();
  }

  /// Verify incoming PIN code with lockout protection
  bool verifyPin(String candidatePin) {
    debugPrint('[LanSecurityService] Verifying pairing PIN');
    if (_lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!)) {
      debugPrint(
        '[LanSecurityService] PIN verification locked out until $_lockoutUntil',
      );
      return false;
    }

    final currentPin = activePin;

    // 1. Verify against current active PIN
    if (currentPin != null && candidatePin == currentPin) {
      debugPrint(
        '[LanSecurityService] PIN verified successfully (current PIN match)',
      );
      _failedPinAttempts = 0;
      return true;
    }

    // 2. Verify against previous PIN with 15-second grace period (75s total from previous generation)
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

  bool get isLockedOut =>
      _lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!);

  /// Returns the current rotating PIN candidates for the SRP-6a exchange.
  /// Each candidate receives an independent salt and exponent.
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

  void recordPairingAuthenticationSuccess() {
    _failedPinAttempts = 0;
    _lockoutUntil = null;
  }

  void recordPairingAuthenticationFailure() {
    _failedPinAttempts++;
    if (_failedPinAttempts >= 3) {
      _lockoutUntil = DateTime.now().add(const Duration(seconds: 30));
    }
  }

  /// Check if a remote device certificate fingerprint is trusted (TOFU)
  Future<bool> isDeviceTrusted(String certFingerprint) async {
    final rawList = await _secureStorage.read(key: _trustedDevicesStorageKey);
    if (rawList == null) return false;
    try {
      final List<dynamic> list = jsonDecode(rawList);
      return list.contains(certFingerprint);
    } catch (_) {
      return false;
    }
  }

  /// Trust a remote device's certificate fingerprint
  Future<void> trustDevice(String certFingerprint) async {
    final rawList = await _secureStorage.read(key: _trustedDevicesStorageKey);
    final Set<String> trustedSet = {};
    if (rawList != null) {
      try {
        final List<dynamic> list = jsonDecode(rawList);
        trustedSet.addAll(list.cast<String>());
      } catch (_) {}
    }
    trustedSet.add(certFingerprint);
    await _secureStorage.write(
      key: _trustedDevicesStorageKey,
      value: jsonEncode(trustedSet.toList()),
    );
  }

  /// Forget a trusted device
  Future<void> untrustDevice(String certFingerprint) async {
    final rawList = await _secureStorage.read(key: _trustedDevicesStorageKey);
    if (rawList == null) return;
    try {
      final List<dynamic> list = jsonDecode(rawList);
      final Set<String> trustedSet = list.cast<String>().toSet();
      trustedSet.remove(certFingerprint);
      await _secureStorage.write(
        key: _trustedDevicesStorageKey,
        value: jsonEncode(trustedSet.toList()),
      );
    } catch (_) {}
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

  Future<Map<String, String>> _loadInboundAccessTokens() async {
    return _inboundAccessTokenCache ??= await _readAccessTokenMap(
      _inboundAccessTokensStorageKey,
    );
  }

  Future<Map<String, String>> _loadOutboundAccessTokens() async {
    return _outboundAccessTokenCache ??= await _readAccessTokenMap(
      _outboundAccessTokensStorageKey,
    );
  }

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

  Future<String?> getOutboundAccessToken(String deviceId) async {
    final tokens = await _loadOutboundAccessTokens();
    return tokens[deviceId];
  }

  /// Records that this process has just verified the peer's PIN and persisted
  /// the credential returned by that peer. This proof is intentionally
  /// memory-only and short-lived: an abandoned token from an older one-sided
  /// attempt must never satisfy a later reciprocal pairing check by itself.
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

  /// Legacy test hook retained for source compatibility. Unbound proofs are
  /// deliberately never accepted by the production reciprocal check.
  @visibleForTesting
  void markFreshOutboundPinProof(String deviceId) {
    if (deviceId.isEmpty || deviceId.length > 128) {
      throw ArgumentError('Invalid LAN pairing device ID.');
    }
    _pruneFreshOutboundPinProofs();
    _freshOutboundPinProofExpiry['legacy\u0000$deviceId'] = DateTime.now().add(
      _freshOutboundPinProofTtl,
    );
  }

  @visibleForTesting
  bool hasFreshOutboundPinProof(String deviceId) {
    _pruneFreshOutboundPinProofs();
    final expiresAt = _freshOutboundPinProofExpiry['legacy\u0000$deviceId'];
    return expiresAt != null && DateTime.now().isBefore(expiresAt);
  }

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
    final expiresAt =
        _freshOutboundPinProofExpiry.remove(proofKey) ??
        _freshOutboundPinProofExpiry.remove('legacy\u0000$deviceId');
    return expiresAt != null && DateTime.now().isBefore(expiresAt);
  }

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

  Future<bool> hasCompleteOutboundPairCredential(String deviceId) async {
    final token = await getOutboundAccessToken(deviceId);
    if (token == null || token.isEmpty) return false;
    return hasPeerCertificateFingerprint(deviceId);
  }

  void _pruneFreshOutboundPinProofs() {
    final now = DateTime.now();
    _freshOutboundPinProofExpiry.removeWhere(
      (_, expiresAt) => !now.isBefore(expiresAt),
    );
  }

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

  Future<bool> hasOutboundAccessToken(String deviceId) async {
    final token = await getOutboundAccessToken(deviceId);
    return token != null && token.isNotEmpty;
  }

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

  Future<String?> getPeerCertificateFingerprint(String deviceId) async {
    final fingerprints = await _loadPeerCertificateFingerprints();
    return fingerprints[deviceId];
  }

  Future<bool> hasPeerCertificateFingerprint(String deviceId) async {
    final fingerprint = await getPeerCertificateFingerprint(deviceId);
    return fingerprint != null && fingerprint.isNotEmpty;
  }

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

  /// Check if a remote device is paired
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async {
    // 1. If cache is not yet loaded, read from disk once.
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
    // timestamp == 0 means permanently paired (bi-directionally confirmed)
    if (timestamp == 0) {
      return true;
    }

    // Temporary pairing: check 1-minute expiry
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - timestamp > 60000) {
      cache.remove(deviceId);
      // Persist removal asynchronously to avoid blocking
      unawaited(
        _secureStorage.write(
          key: _pairedDevicesStorageKey,
          value: jsonEncode(cache),
        ),
      );
      return false;
    }

    // Kick off background remote verification to upgrade temporary -> permanent
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
                // Upgrade to permanent pair in both cache and disk
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

  /// Force the in-memory paired-device cache to reload on next access.
  /// Useful in tests that mutate FlutterSecureStorage directly.
  void invalidatePairedCache() => _pairedCache = null;

  Future<void> _loadPairedCacheFromDisk() async {
    final rawList = await _secureStorage.read(key: _pairedDevicesStorageKey);
    if (rawList == null) {
      _pairedCache = {};
      return;
    }
    final Map<String, int> result = {};
    try {
      final Map<String, dynamic> decoded = jsonDecode(rawList);
      result.addAll(decoded.map((k, v) => MapEntry(k, v as int)));
    } catch (_) {
      try {
        final List<dynamic> list = jsonDecode(rawList);
        for (final id in list) {
          result[id as String] = 0;
        }
      } catch (_) {}
    }
    _pairedCache = result;
  }

  /// Pair a remote device
  Future<void> pairDevice(String deviceId) async {
    if (_pairedCache == null) await _loadPairedCacheFromDisk();
    final cache = _pairedCache!;
    cache[deviceId] = DateTime.now().millisecondsSinceEpoch;
    await _secureStorage.write(
      key: _pairedDevicesStorageKey,
      value: jsonEncode(cache),
    );
  }

  /// Persist a pairing after both devices have verified each other's PIN.
  /// A zero timestamp is permanent; temporary timestamps remain reserved for
  /// legacy one-sided pairing records that still require a remote check.
  Future<void> confirmDevicePairing(String deviceId) async {
    if (_pairedCache == null) await _loadPairedCacheFromDisk();
    final cache = _pairedCache!;
    cache[deviceId] = 0;
    await _secureStorage.write(
      key: _pairedDevicesStorageKey,
      value: jsonEncode(cache),
    );
  }

  /// Unpair a remote device
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

  /// Unpair all devices
  Future<void> unpairAllDevices() async {
    _pairedCache = {};
    _inboundAccessTokenCache = {};
    _outboundAccessTokenCache = {};
    _freshOutboundPinProofExpiry.clear();
    await Future.wait([
      _secureStorage.delete(key: _pairedDevicesStorageKey),
      _secureStorage.delete(key: _inboundAccessTokensStorageKey),
      _secureStorage.delete(key: _outboundAccessTokensStorageKey),
      _secureStorage.delete(key: _peerCertificateFingerprintsStorageKey),
      _secureStorage.delete(key: _peerX25519KeysStorageKey),
      _secureStorage.delete(key: _peerNetworkIdentityKeysStorageKey),
    ]);
  }

  Future<String> getLocalCertificateFingerprint(String deviceId) async {
    await getOrCreateSecurityContext(deviceId);
    final pem = _cachedCertPem;
    if (pem == null) throw StateError('LAN certificate is unavailable.');
    return computeCertFingerprint(pem);
  }

  static String _certificateFingerprintFromDer(Uint8List der) {
    // Keep the callback synchronous; the protocol uses the same SHA-256
    // representation as computeCertFingerprint().
    return crypto.sha256.convert(der).toString();
  }
}
