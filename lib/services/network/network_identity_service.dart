import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class NetworkIdentityMaterial {
  const NetworkIdentityMaterial({
    required this.privateSeed,
    required this.publicKey,
  });

  final Uint8List privateSeed;
  final Uint8List publicKey;
}

/// Owns the QUIC Ed25519 identity independently from Relay signing and X25519
/// content-encryption keys.
class NetworkIdentityService {
  NetworkIdentityService({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _identitySeedKey = 'network_quic_ed25519_seed_v1';
  final FlutterSecureStorage _secureStorage;
  NetworkIdentityMaterial? _cached;

  Future<NetworkIdentityMaterial> loadOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;
    final algorithm = Ed25519();
    final stored = await _secureStorage.read(key: _identitySeedKey);
    final SimpleKeyPair keyPair;
    if (stored == null) {
      keyPair = await algorithm.newKeyPair();
      final seed = await keyPair.extractPrivateKeyBytes();
      await _secureStorage.write(
        key: _identitySeedKey,
        value: base64UrlEncode(seed).replaceAll('=', ''),
      );
    } else {
      final seed = base64Url.decode(base64Url.normalize(stored));
      if (seed.length != 32) {
        throw StateError('Stored QUIC identity seed is invalid.');
      }
      keyPair = await algorithm.newKeyPairFromSeed(seed);
    }
    final privateSeed = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final material = NetworkIdentityMaterial(
      privateSeed: Uint8List.fromList(privateSeed),
      publicKey: Uint8List.fromList(publicKey.bytes),
    );
    _cached = material;
    return material;
  }
}
