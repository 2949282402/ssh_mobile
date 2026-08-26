import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:network_sdk/network_sdk.dart';

enum PeerTrustOrigin { localPin }

final class PeerRouteAuthorization {
  const PeerRouteAuthorization({
    required this.localDirect,
    required this.relay,
  });

  final bool localDirect;
  final bool relay;

  PeerRouteAuthorization copyWith({bool? localDirect, bool? relay}) =>
      PeerRouteAuthorization(
        localDirect: localDirect ?? this.localDirect,
        relay: relay ?? this.relay,
      );
}

/// Checks whether an incoming route type is authorized by the peer's trust authorization.
///
/// Strictly fail-closed: [NetworkRouteType.unspecified] is never authorized.
bool isIncomingRouteAuthorized(
  PeerRouteAuthorization authorization,
  NetworkRouteType routeType,
) => switch (routeType) {
  NetworkRouteType.lan ||
  NetworkRouteType.quicDirect => authorization.localDirect,
  NetworkRouteType.relay => authorization.relay,
  NetworkRouteType.unspecified => false,
};

final class LanPeerTrustRecord {
  LanPeerTrustRecord({
    required this.deviceId,
    required this.certificateFingerprint,
    required this.inboundAccessToken,
    required this.outboundAccessToken,
    required Uint8List x25519PublicKey,
    required Uint8List networkIdentityPublicKey,
    required this.origin,
    required this.authorization,
    required this.createdAt,
  }) : x25519PublicKey = Uint8List.fromList(x25519PublicKey),
       networkIdentityPublicKey = Uint8List.fromList(networkIdentityPublicKey) {
    _validate();
  }

  final String deviceId;
  final String certificateFingerprint;
  final String inboundAccessToken;
  final String outboundAccessToken;
  final Uint8List x25519PublicKey;
  final Uint8List networkIdentityPublicKey;
  final PeerTrustOrigin origin;
  final PeerRouteAuthorization authorization;
  final DateTime createdAt;

  /// The fields below are the peer identity, rather than mutable route or
  /// credential state.  A pairing may rotate bearer tokens, but it must never
  /// silently replace the certificate or either static public key.
  bool hasSameIdentity(LanPeerTrustRecord other) =>
      deviceId == other.deviceId &&
      certificateFingerprint.toLowerCase() ==
          other.certificateFingerprint.toLowerCase() &&
      _constantTimeBytesEqual(x25519PublicKey, other.x25519PublicKey) &&
      _constantTimeBytesEqual(
        networkIdentityPublicKey,
        other.networkIdentityPublicKey,
      );

  LanPeerTrustRecord copyWith({
    String? inboundAccessToken,
    String? outboundAccessToken,
    PeerRouteAuthorization? authorization,
  }) => LanPeerTrustRecord(
    deviceId: deviceId,
    certificateFingerprint: certificateFingerprint,
    inboundAccessToken: inboundAccessToken ?? this.inboundAccessToken,
    outboundAccessToken: outboundAccessToken ?? this.outboundAccessToken,
    x25519PublicKey: x25519PublicKey,
    networkIdentityPublicKey: networkIdentityPublicKey,
    origin: origin,
    authorization: authorization ?? this.authorization,
    createdAt: createdAt,
  );

  void _validate() {
    if (deviceId.isEmpty || deviceId.length > 128) {
      throw const FormatException('Invalid trusted peer device ID.');
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(certificateFingerprint)) {
      throw const FormatException('Invalid trusted peer certificate.');
    }
    if (inboundAccessToken.isEmpty || inboundAccessToken.length > 256) {
      throw const FormatException('Invalid inbound access token.');
    }
    if (outboundAccessToken.isEmpty || outboundAccessToken.length > 256) {
      throw const FormatException('Invalid outbound access token.');
    }
    if (x25519PublicKey.length != 32 || networkIdentityPublicKey.length != 32) {
      throw const FormatException('Invalid trusted peer public key.');
    }
    if (!authorization.localDirect && authorization.relay) {
      throw const FormatException('Relay-only trust is not supported.');
    }
    if (!authorization.localDirect && !authorization.relay) {
      throw const FormatException('Trusted peer has no authorized route.');
    }
  }

  Map<String, Object> toJson() => <String, Object>{
    'deviceId': deviceId,
    'certificateFingerprint': certificateFingerprint.toLowerCase(),
    'inboundAccessToken': inboundAccessToken,
    'outboundAccessToken': outboundAccessToken,
    'x25519PublicKey': base64UrlEncode(x25519PublicKey),
    'networkIdentityPublicKey': base64UrlEncode(networkIdentityPublicKey),
    'origin': origin.name,
    'localDirect': authorization.localDirect,
    'relay': authorization.relay,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory LanPeerTrustRecord.fromJson(Map<String, dynamic> json) =>
      LanPeerTrustRecord(
        deviceId: json['deviceId'] as String? ?? '',
        certificateFingerprint: json['certificateFingerprint'] as String? ?? '',
        inboundAccessToken: json['inboundAccessToken'] as String? ?? '',
        outboundAccessToken: json['outboundAccessToken'] as String? ?? '',
        x25519PublicKey: _decodeKey(json['x25519PublicKey']),
        networkIdentityPublicKey: _decodeKey(json['networkIdentityPublicKey']),
        origin: PeerTrustOrigin.values.byName(json['origin'] as String? ?? ''),
        authorization: PeerRouteAuthorization(
          localDirect: json['localDirect'] == true,
          relay: json['relay'] == true,
        ),
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
            (throw const FormatException('Invalid trust creation time.')),
      );

  static Uint8List _decodeKey(Object? value) {
    if (value is! String) throw const FormatException('Missing peer key.');
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
  }

  static bool _constantTimeBytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}

final class LanPeerTrustStore {
  LanPeerTrustStore({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const int schemaVersion = 2;
  static const String _storageKey = 'lan_share_peer_trust_v2';
  // These keys are deletion targets only. V2 never reads or writes their
  // fragmented values as trust state.
  static const List<String> _legacyKeys = <String>[
    'lan_share_paired_device_ids',
    'lan_share_inbound_access_tokens',
    'lan_share_outbound_access_tokens',
    'lan_share_peer_certificate_fingerprints',
    'lan_share_peer_x25519_keys_v1',
    'lan_share_peer_network_identity_keys_v1',
    'lan_share_trusted_fingerprints',
  ];

  final FlutterSecureStorage _secureStorage;
  final StreamController<List<LanPeerTrustRecord>> _changes =
      StreamController<List<LanPeerTrustRecord>>.broadcast();
  Future<void> _writeSerial = Future<void>.value();
  Map<String, LanPeerTrustRecord>? _cache;

  Stream<List<LanPeerTrustRecord>> get changes => _changes.stream;

  Future<List<LanPeerTrustRecord>> loadAll() async {
    final records = await _load();
    return List<LanPeerTrustRecord>.unmodifiable(records.values);
  }

  Future<LanPeerTrustRecord?> read(String deviceId) async =>
      (await _load())[deviceId];

  Future<void> save(LanPeerTrustRecord record) => _serialize(() async {
    final records = Map<String, LanPeerTrustRecord>.from(await _load());
    final existing = records[record.deviceId];
    if (existing != null && !existing.hasSameIdentity(record)) {
      throw StateError(
        'LAN peer identity changed; unpair before pairing again.',
      );
    }
    records[record.deviceId] = record;
    await _persist(records);
  });

  Future<void> delete(String deviceId) => _serialize(() async {
    final records = Map<String, LanPeerTrustRecord>.from(await _load());
    if (records.remove(deviceId) != null) await _persist(records);
  });

  Future<void> setRelayAuthorization(String deviceId, bool authorized) =>
      _serialize(() async {
        final records = Map<String, LanPeerTrustRecord>.from(await _load());
        final current = records[deviceId];
        if (current == null) throw StateError('Trusted peer is unavailable.');
        records[deviceId] = current.copyWith(
          authorization: current.authorization.copyWith(relay: authorized),
        );
        await _persist(records);
      });

  Future<Map<String, LanPeerTrustRecord>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await _secureStorage.read(key: _storageKey);
    if (raw == null) {
      await _clearLegacyState();
      await _persist(<String, LanPeerTrustRecord>{});
      return _cache!;
    }
    try {
      final document = jsonDecode(raw) as Map<String, dynamic>;
      if (document['schemaVersion'] != schemaVersion) {
        throw const FormatException();
      }
      final values = document['records'] as List<dynamic>;
      final records = <String, LanPeerTrustRecord>{};
      for (final value in values) {
        final record = LanPeerTrustRecord.fromJson(
          value as Map<String, dynamic>,
        );
        if (records.containsKey(record.deviceId)) throw const FormatException();
        records[record.deviceId] = record;
      }
      // A valid V2 document is authoritative.  Remove any stale fragmented
      // Legacy material as well so no caller can accidentally consult it later.
      await _clearLegacyState();
      return _cache = records;
    } on Object {
      await _secureStorage.delete(key: _storageKey);
      await _clearLegacyState();
      await _persist(<String, LanPeerTrustRecord>{});
      return _cache!;
    }
  }

  Future<void> _persist(Map<String, LanPeerTrustRecord> records) async {
    await _secureStorage.write(
      key: _storageKey,
      value: jsonEncode(<String, Object>{
        'schemaVersion': schemaVersion,
        'records': records.values.map((record) => record.toJson()).toList(),
      }),
    );
    _cache = records;
    if (!_changes.isClosed) {
      _changes.add(List<LanPeerTrustRecord>.unmodifiable(records.values));
    }
  }

  Future<void> _clearLegacyState() async {
    for (final key in _legacyKeys) {
      await _secureStorage.delete(key: key);
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _writeSerial.then((_) => action());
    _writeSerial = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> dispose() async {
    await _writeSerial;
    await _changes.close();
  }
}

/// Snapshot of a peer's persistent trust and current runtime authorization policy.
final class LanPeerPolicySnapshot {
  const LanPeerPolicySnapshot({
    this.trust,
    this.runtimeBlocked = false,
    this.revoked = false,
  });

  final LanPeerTrustRecord? trust;
  final bool runtimeBlocked;
  final bool revoked;

  bool get isTrusted => trust != null && !revoked && !runtimeBlocked;
  bool get allowDirect =>
      isTrusted && (trust?.authorization.localDirect ?? false);
  bool get allowRelay => isTrusted && (trust?.authorization.relay ?? false);
}

/// Isolated report of trusted peer restoration for a native generation.
final class LanPeerRestoreReport {
  const LanPeerRestoreReport({
    required this.restoredPeerIds,
    required this.blockedPeerIds,
    required this.failures,
  });

  final List<String> restoredPeerIds;
  final List<String> blockedPeerIds;
  final Map<String, NetworkError> failures;

  bool get isFullSuccess => failures.isEmpty && blockedPeerIds.isEmpty;
}

/// Authority port for native peer policy and persisted trust reconciliation.
abstract interface class LanNativePeerPolicyPort {
  Future<NetworkResult<LanPeerPolicySnapshot>> getPeerPolicy(String peerId);

  Future<NetworkResult<void>> updateDirectEndpoint(
    String peerId,
    String endpoint,
  );

  Future<NetworkResult<void>> invalidateDirectEndpoint(String peerId);

  Future<NetworkResult<void>> setRelayAuthorization(
    String peerId,
    bool enabled,
  );

  Future<NetworkResult<void>> removeTrust(String peerId);

  Future<NetworkResult<void>> reconcilePersistedTrust(
    LanPeerTrustRecord record,
  );
}
