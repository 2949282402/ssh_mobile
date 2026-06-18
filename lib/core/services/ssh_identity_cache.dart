import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class SshIdentityCache {
  static final Map<SshIdentityCacheKey, List<SSHKeyPair>> _cache = {};

  static List<SSHKeyPair>? get(SshIdentityCacheKey key) => _cache[key];

  static void put(SshIdentityCacheKey key, List<SSHKeyPair> identities) {
    _cache[key] = identities;
  }

  static void clearAll() {
    _cache.clear();
  }

  static void clearForConnection(String connectionId) {
    _cache.removeWhere((key, _) => key.connectionId == connectionId);
  }

  @visibleForTesting
  static int get debugEntryCount => _cache.length;
}

@immutable
class SshIdentityCacheKey {
  final String connectionId;
  final String privateKeyDigest;
  final String? passphraseDigest;

  SshIdentityCacheKey({
    required this.connectionId,
    required String privateKey,
    required String? passphrase,
  })  : privateKeyDigest = _digest(privateKey),
        passphraseDigest = passphrase == null ? null : _digest(passphrase);

  static String _digest(String value) {
    return sha256.convert(utf8.encode(value)).toString();
  }

  @override
  bool operator ==(Object other) {
    return other is SshIdentityCacheKey &&
        other.connectionId == connectionId &&
        other.privateKeyDigest == privateKeyDigest &&
        other.passphraseDigest == passphraseDigest;
  }

  @override
  int get hashCode =>
      Object.hash(connectionId, privateKeyDigest, passphraseDigest);
}
