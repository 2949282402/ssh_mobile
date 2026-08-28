// ignore_for_file: prefer_initializing_formals

// Native Network V2 peer registry for LAN trust records.
//
// The registry remains the sole owner of trust-to-native synchronization.
// Reconciliation/policy and ephemeral discovery observations live in parts so
// lifecycle, authorization, and pruning concerns stay independently readable.

import 'dart:async';

import 'package:network_sdk/network_sdk.dart';

import '../../../services/lan_share/lan_network_models.dart';
import '../../../services/lan_share/lan_peer_trust.dart';
import '../../../services/lan_share/lan_share_models.dart';

part 'lan_native_peer_registry_observation.dart';
part 'lan_native_peer_registry_policy.dart';

final class LanNativePeerRegistry implements LanNativePeerPolicyPort {
  LanNativePeerRegistry({
    required this.trustStore,
    NetworkFacade? networkFacade,
  }) : _networkFacade = networkFacade;

  final LanPeerTrustStore trustStore;
  NetworkFacade? _networkFacade;
  final Map<String, String> _directEndpoints = <String, String>{};
  final Map<String, Future<void>> _peerMutationSerial =
      <String, Future<void>>{};
  final Set<String> _revokedPeerIds = <String>{};
  final Set<String> _blockedPeerIds = <String>{};

  /// Whether the peer is currently blocked in this runtime generation due to
  /// failed native peer cleanup or failed reconciliation.
  bool isPeerBlocked(String deviceId) => _blockedPeerIds.contains(deviceId);

  /// Whether the peer has been explicitly revoked in this runtime generation.
  bool isPeerRevoked(String deviceId) => _revokedPeerIds.contains(deviceId);

  /// The registry borrows the App-owned facade for the current runtime
  /// generation. It never starts, stops, or disposes that facade.
  NetworkFacade? get networkFacade => _networkFacade;

  /// Attach the facade after the App runtime has completed configuration.
  void attachFacade(NetworkFacade facade) {
    _networkFacade = facade;
  }

  /// Detach the current facade without touching its lifecycle.
  ///
  /// Direct endpoints are generation-scoped discovery state. Trust records
  /// remain persisted in [trustStore] and will be restored with an empty
  /// endpoint when the next generation is attached.
  void detachFacade() {
    _networkFacade = null;
    _directEndpoints.clear();
  }

  /// Resolve a trusted native peer from its current discovery endpoint.
  String? peerIdForEndpoint(String host, int port) {
    final key = _endpointKey(host, port);
    if (key == null) return null;

    String? match;
    for (final entry in _directEndpoints.entries) {
      if (_endpointKeyFromEndpoint(entry.value) != key) continue;
      if (match != null && match != entry.key) return null;
      match = entry.key;
    }
    return match;
  }

  /// Resolve a trusted native peer by its current direct host.
  ///
  /// SSH's configured port is the remote SSH service port, while the native
  /// stream endpoint uses its own advertised port. Consequently this lookup
  /// intentionally ignores ports and succeeds only when exactly one active
  /// trusted peer owns the host. Multiple peers on one host fail closed.
  String? peerIdForHost(String host) {
    final normalizedHost = _hostKey(host);
    if (normalizedHost == null) return null;

    String? match;
    for (final entry in _directEndpoints.entries) {
      if (_hostKeyFromEndpoint(entry.value) != normalizedHost) continue;
      if (match != null && match != entry.key) return null;
      match = entry.key;
    }
    return match;
  }

  /// Restores all persisted trust records into the current native generation.
  Future<LanPeerRestoreReport> restoreAll() => _restoreAll();

  @override
  Future<NetworkResult<LanPeerPolicySnapshot>> getPeerPolicy(String peerId) =>
      _getPeerPolicy(peerId);

  @override
  Future<NetworkResult<void>> reconcilePersistedTrust(
    LanPeerTrustRecord record,
  ) => _reconcilePersistedTrust(record);

  @override
  Future<NetworkResult<void>> updateDirectEndpoint(
    String deviceId,
    String endpoint,
  ) => _updateDirectEndpoint(deviceId, endpoint);

  @override
  Future<NetworkResult<void>> invalidateDirectEndpoint(String deviceId) =>
      _invalidateDirectEndpoint(deviceId);

  @override
  Future<NetworkResult<void>> setRelayAuthorization(
    String deviceId,
    bool enabled,
  ) => enabled ? authorizeRelayForPeer(deviceId) : revokeRelayForPeer(deviceId);

  Future<NetworkResult<void>> authorizeRelayForPeer(String deviceId) =>
      _authorizeRelayForPeer(deviceId);

  Future<NetworkResult<void>> revokeRelayForPeer(String deviceId) =>
      _revokeRelayForPeer(deviceId);

  @override
  Future<NetworkResult<void>> removeTrust(String deviceId) =>
      _removeTrust(deviceId);

  /// Reconcile discovery's ephemeral native endpoints with trusted peers.
  ///
  /// The discovery snapshot is deliberately not a source of trust. Unknown
  /// devices are ignored, and peers missing from the snapshot are merely
  /// re-registered without a direct endpoint; their trust records remain.
  Future<void> syncDiscoveredEndpoints(Iterable<LanDiscoveredPeer> peers) =>
      _syncDiscoveredEndpoints(peers);

  /// Applies one discovery observation without treating it as a complete
  /// snapshot. Discovery streams emit full snapshots, but pairing/receiver
  /// callbacks often carry only the peer that just changed.
  Future<void> observeDiscoveredEndpoint(LanDiscoveredPeer peer) =>
      _observeDiscoveredEndpoint(peer);

  NetworkFacade _requireFacade() =>
      _networkFacade ??
      (throw StateError('Native network facade is unavailable.'));
}
