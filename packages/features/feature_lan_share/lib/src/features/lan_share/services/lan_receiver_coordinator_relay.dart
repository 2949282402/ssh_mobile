part of 'lan_receiver_coordinator.dart';

/// Relay enrollment and explicit peer-policy actions.
extension LanReceiverCoordinatorRelay on LanReceiverCoordinator {
  /// 仅保存 Relay origin；端点变化会断开旧 socket 并清除旧 enrollment。
  Future<NetworkResult<void>> saveRelayEndpoint(Uri endpoint) async {
    await ensureInitialized();
    return _relayCoordinator!.saveEndpoint(endpoint);
  }

  /// 完成凭据 enrollment，并配置原生 Relay 数据面。
  Future<NetworkResult<void>> enrollRelay({
    required Uri endpoint,
    required String enrollmentToken,
  }) async {
    await ensureInitialized();
    return _relayCoordinator!.enroll(
      endpoint: endpoint,
      enrollmentToken: enrollmentToken,
    );
  }

  /// 加载已存储 enrollment，并配置原生 Relay 连接。
  Future<NetworkResult<void>> connectConfiguredRelay() async {
    await ensureInitialized();
    return _relayCoordinator!.connectConfigured();
  }

  /// 主动断开 Relay，但保留 endpoint 和 enrollment 供下次连接使用。
  Future<NetworkResult<void>> disconnectRelay() async {
    await ensureInitialized();
    return _relayCoordinator!.disconnect();
  }

  /// 清除 endpoint 与短期 enrollment credential，但保留设备签名种子。
  Future<NetworkResult<void>> clearRelayEnrollment() async {
    await ensureInitialized();
    return _relayCoordinator!.clearEnrollment();
  }

  /// Explicitly revoke one complete trust record and its native peer.
  ///
  /// Discovery loss, relay disconnect, and Feature deactivation never call
  /// this method; only an explicit unpair action may remove trust.
  Future<NetworkResult<void>> removeTrustedPeer(String deviceId) async {
    await ensureInitialized();
    return peerRegistry.removeTrust(deviceId);
  }

  Future<NetworkResult<void>> authorizeRelayForPeer(String deviceId) async {
    await ensureInitialized();
    return peerRegistry.authorizeRelayForPeer(deviceId);
  }

  Future<NetworkResult<void>> revokeRelayForPeer(String deviceId) async {
    await ensureInitialized();
    return peerRegistry.revokeRelayForPeer(deviceId);
  }
}
