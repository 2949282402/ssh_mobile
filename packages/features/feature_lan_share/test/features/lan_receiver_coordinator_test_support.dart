part of 'lan_receiver_coordinator_test.dart';

/// 构建一个注入 fake 网络、runtime 与 bootstrap 的 Relay 协调器。
LanReceiverCoordinator _buildRelayCoordinator(
  LanShareDatabase database,
  FakeLanShareSettings settings,
  FakeLanShareNetworkService networkService,
  FakeLanShareBootstrapClient bootstrapClient,
) {
  return LanReceiverCoordinator(
    appSettings: settings,
    logger: FakeLanShareLogger(),
    dataProtection: FakeLanShareDataProtection(),
    networkIdentity: FakeLanShareIdentity(),
    networkAccess: FakeLanShareNetworkAccessPort(networkFacade: networkService),
    bootstrapClient: bootstrapClient,
    historyRepository: LanShareHistoryRepository(database),
    networkRuntime: FakeLanShareNetworkRuntime(),
    transferServiceOverride: FakeLanTransferService(),
    discoveryServiceOverride: FakeLanDiscoveryService(),
  );
}

/// 返回可写的应用文档目录，避免单元测试依赖平台插件通道。
final class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/lan_share_test_documents';

  @override
  Future<String?> getTemporaryPath() async => '/tmp/lan_share_test_tmp';
}

String _encodedKey(int length, int value) =>
    base64UrlEncode(List<int>.filled(length, value)).replaceAll('=', '');

void _seedMalformedTrust({String? identityKey, String? e2eKey}) {
  FlutterSecureStorage.setMockInitialValues(<String, String>{
    'lan_share_peer_trust_v2': jsonEncode(<String, Object?>{
      'schemaVersion': LanPeerTrustStore.schemaVersion,
      'records': <Map<String, Object?>>[
        <String, Object?>{
          'deviceId': 'peer-a',
          'certificateFingerprint': 'a' * 64,
          'inboundAccessToken': 'inbound-peer-a',
          'outboundAccessToken': 'outbound-peer-a',
          'x25519PublicKey': e2eKey,
          'networkIdentityPublicKey': identityKey,
          'origin': PeerTrustOrigin.localPin.name,
          'localDirect': true,
          'relay': false,
          'createdAt': DateTime.utc(2026).toIso8601String(),
        },
      ],
    }),
  });
}

LanPeerTrustRecord _trustRecord(String deviceId) => LanPeerTrustRecord(
  deviceId: deviceId,
  certificateFingerprint: 'a' * 64,
  inboundAccessToken: 'inbound-$deviceId',
  outboundAccessToken: 'outbound-$deviceId',
  x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
  networkIdentityPublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026),
);

IncomingTransferOffer _offer(String id) => IncomingTransferOffer(
  eventId: 'event-$id',
  timestamp: DateTime.now(),
  transferId: id,
  peerId: 'peer-a',
  fileName: '$id.bin',
  fileSize: 1,
  routeType: NetworkRouteType.quicDirect,
);
