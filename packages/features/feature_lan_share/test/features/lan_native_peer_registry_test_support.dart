part of 'lan_native_peer_registry_v2_test.dart';

final class _FailingSecureStorage extends Fake implements FlutterSecureStorage {
  bool failWrite = false;
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrite) {
      throw Exception('Simulated secure storage write failure');
    }
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data.remove(key);
  }
}

final class _RecordingFacade extends Fake implements NetworkFacade {
  final List<SdkPeerConfig> registrations = <SdkPeerConfig>[];
  final List<String> removedPeerIds = <String>[];
  final List<String> disconnectedPeerIds = <String>[];
  int connectCalls = 0;
  int registerPeerCalls = 0;
  bool failRegisterPeer = false;
  int? failRegisterPeerOnCall;
  bool failRemovePeer = false;
  bool failDisconnectPeer = false;

  @override
  Future<SdkResult<void>> registerPeer(SdkPeerConfig peer) async {
    registerPeerCalls++;
    if (failRegisterPeer ||
        (failRegisterPeerOnCall != null &&
            registerPeerCalls == failRegisterPeerOnCall)) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Simulated native registerPeer failure.',
          operation: NetworkOperation.upsertPeer,
          peerId: peer.peerId,
        ),
      );
    }
    registrations.add(peer);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> removePeer(String peerId) async {
    if (failRemovePeer) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Simulated native removePeer failure.',
          operation: NetworkOperation.removePeer,
          peerId: peerId,
        ),
      );
    }
    removedPeerIds.add(peerId);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> disconnectPeer(String peerId) async {
    if (failDisconnectPeer) {
      return NetworkFailure<void>(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'Simulated native disconnectPeer failure.',
          operation: NetworkOperation.disconnect,
          peerId: peerId,
        ),
      );
    }
    disconnectedPeerIds.add(peerId);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    connectCalls++;
    return const SdkSuccess<void>(null);
  }
}

LanPeerTrustRecord _record(String deviceId) => LanPeerTrustRecord(
  deviceId: deviceId,
  certificateFingerprint:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  inboundAccessToken: 'inbound-$deviceId',
  outboundAccessToken: 'outbound-$deviceId',
  x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
  networkIdentityPublicKey: Uint8List.fromList(List<int>.filled(32, 0x22)),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026, 1, 1),
);

LanDiscoveredPeer _discovered(String deviceId, String ip, int nativePort) =>
    LanDiscoveredPeer(
      deviceId: deviceId,
      alias: deviceId,
      ip: ip,
      controlPort: 53317,
      advertisedNativePort: nativePort,
      deviceType: LanDeviceType.desktop,
      os: 'linux',
      lastSeen: DateTime.utc(2026),
    );
