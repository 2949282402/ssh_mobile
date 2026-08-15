import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';

final class FakeLanShareStrings extends Fake implements LanShareStrings {
  FakeLanShareStrings({this.english = false});

  final bool english;

  @override
  bool get isEnglish => english;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName == #isEnglish ? english : '';
}

final class FakeLanShareSettings extends ChangeNotifier
    implements LanShareSettingsPort {
  FakeLanShareSettings({this.english = false, this.relayEndpoint = ''});

  final bool english;

  /// 已保存的 Relay origin；默认空字符串表示未配置。
  @override
  final String relayEndpoint;
  final FakeLanShareStrings _strings = FakeLanShareStrings();

  @override
  LanShareLanguage get language =>
      english ? LanShareLanguage.en : LanShareLanguage.zh;

  @override
  bool get isEnglish => english;

  @override
  LanShareStrings get strings => _strings;

  @override
  String get lanDeviceId => 'test-device';

  @override
  String get lanDeviceAlias => 'Test Device';

  @override
  String get relayHost => '';

  @override
  int get relayPort => 443;

  @override
  bool get receiverEnabled => true;

  @override
  Future<void> ensureLanIdentity() async {}

  @override
  Future<void> setLanDeviceAlias(String alias) async {}

  @override
  Future<void> setRelayEndpoint(String endpoint) async {}

  @override
  Future<void> setRelayServer({
    required String host,
    required int port,
  }) async {}
}

final class FakeLanShareLogger implements LanShareLoggerPort {
  final List<String> warnings = [];

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) => warnings.add(message);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

final class FakeLanShareDataProtection implements LanShareDataProtectionPort {
  @override
  Future<String> encryptString(String value) async => 'encrypted:$value';

  @override
  Future<String> decryptString(String value) async =>
      value.startsWith('encrypted:') ? value.substring(10) : value;

  @override
  bool isEncrypted(String value) => value.startsWith('encrypted:');
}

final class FakeLanShareIdentity implements LanShareNetworkIdentityPort {
  @override
  Future<LanShareNetworkIdentityMaterial> loadOrCreate() async =>
      LanShareNetworkIdentityMaterial(
        privateSeed: Uint8List(32),
        publicKey: Uint8List(32),
      );
}

final class FakeLanShareNetworkFactory implements LanShareNetworkFactory {
  FakeLanShareNetworkFactory({this.networkService});

  int createCalls = 0;

  /// 返回给协调器的 NetworkService；null 模拟 App Shell 未创建原生服务。
  final NetworkService? networkService;

  @override
  Future<NetworkService?> create({
    required String deviceId,
    required Uint8List identityPrivateKey,
    required Uint8List e2ePrivateKey,
    required String listenAddress,
    required String receiveDirectory,
  }) async {
    createCalls++;
    return networkService;
  }
}

final class FakeLanShareNetworkRuntime implements NetworkRuntime {
  FakeLanShareNetworkRuntime({this.refuseWebSocketRelay = false});

  int ensureCalls = 0;

  /// 按请求顺序记录已请求的 Capability。
  final List<NetworkCapability> requestedCapabilities = <NetworkCapability>[];

  /// 为 true 时，`webSocketRelay` 请求抛出 `UnsupportedError`。
  final bool refuseWebSocketRelay;
  bool disposed = false;

  @override
  NetworkRuntimeState get state =>
      disposed ? NetworkRuntimeState.disposed : NetworkRuntimeState.idle;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const <NetworkCapability>[],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {
    ensureCalls++;
    requestedCapabilities.add(capability);
    if (refuseWebSocketRelay &&
        capability == NetworkCapability.webSocketRelay) {
      throw UnsupportedError(
        'Network capability is unavailable: ${capability.label}',
      );
    }
  }

  @override
  Future<NetworkCommandGateway> openCommandGateway() async =>
      throw UnsupportedError('fake runtime has no command gateway');

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async =>
      throw UnsupportedError('fake runtime has no realtime gateway');

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 记录 Relay 配置调用且支持受控生命周期的 fake NetworkService。
final class FakeLanShareNetworkService implements NetworkService {
  final StreamController<NetworkEvent> _events =
      StreamController<NetworkEvent>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int configureRelayCalls = 0;
  int disconnectRelayCalls = 0;
  int _eventSequence = 0;
  bool disposed = false;

  @override
  Stream<NetworkEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async {
    startCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> stop() async {
    stopCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) async {
    configureRelayCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> disconnectRelay() async {
    disconnectRelayCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> uploadDiscovery({
    required int generation,
    required List<String> candidates,
    required List<String> capabilities,
  }) async => const SdkSuccess<void>(null);

  /// 向协调器发布一个受控的 Relay 生命周期事件。
  void emitRelayState(RelayConnectionState state, {NetworkError? error}) {
    _events.add(
      RelayStateChanged(
        eventId: 'relay-event-${++_eventSequence}',
        timestamp: DateTime.now(),
        state: state,
        error: error,
      ),
    );
  }

  @override
  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> connect(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> disconnect(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) => throw UnsupportedError('not used in this test');

  @override
  Future<SdkResult<void>> cancel(String transferId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkRouteSnapshot>> state(String peerId) async => SdkSuccess(
    SdkRouteSnapshot(peerId: peerId, routeType: NetworkRouteType.lan),
  );

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

final class FakeLanShareBootstrapClient implements BootstrapClient {
  FakeLanShareBootstrapClient({this.onRefresh});

  /// 可选的 refresh 处理器；缺省返回一个未来过期的假凭据。
  final Future<SdkResult<DeviceEnrollment>> Function(
    Uri endpoint,
    RefreshRequest request,
  )?
  onRefresh;

  int refreshCalls = 0;

  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 1));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async => SdkSuccess(
    DeviceEnrollment(
      deviceId: request.deviceId,
      relayCredential: 'fake',
      expiresAt: DateTime.utc(2030),
      serverTime: DateTime.utc(2029),
      protocolVersion: 1,
    ),
  );

  @override
  Future<SdkResult<DeviceEnrollment>> refresh(
    Uri endpoint,
    RefreshRequest request,
  ) async {
    refreshCalls++;
    final handler = onRefresh;
    if (handler != null) return handler(endpoint, request);
    return SdkSuccess(
      DeviceEnrollment(
        deviceId: request.deviceId,
        relayCredential: 'fake-refreshed',
        expiresAt: DateTime.utc(2030),
        serverTime: DateTime.utc(2029),
        protocolVersion: 1,
      ),
    );
  }
}

final class FakeLanSecurityService extends Fake implements LanSecurityService {
  String? unpairedDeviceId;

  @override
  String? get activePin => '123456';

  @override
  int get pinSecondsRemaining => 60;

  @override
  String getOrGenerate6DigitPin() => activePin!;

  @override
  Future<void> unpairDevice(String deviceId) async {
    unpairedDeviceId = deviceId;
  }
}

final class FakeLanDiscoveryService extends Fake
    implements LanDiscoveryService {
  FakeLanDiscoveryService({this.activeWebShare = false, this.shareUrl});

  final bool activeWebShare;
  final String? shareUrl;

  @override
  bool get isScanning => false;

  @override
  String get currentDeviceId => 'test-device';

  @override
  String get currentDeviceAlias => 'Test Device';

  @override
  bool get isWebShareActive => activeWebShare;

  @override
  String? get webShareUrl => shareUrl;

  @override
  Future<NetworkResult<void>> startDiscovery() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> startAdvertising({
    int port = LanDiscoveryService.defaultPort,
  }) async => const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> stopDiscovery() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> stopAdvertising() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> stopWebShareServer() async =>
      const NetworkSuccess<void>(null);

  @override
  void dispose() {}
}

/// 支持受控监听端口和启停计数的 fake LAN 传输服务。
///
/// 默认模拟一个已可绑定端口（`LanTransferService.defaultHttpPort`）的服务，
/// 让 Coordinator 在 `initializeNetwork: true` 时能走到 native runtime
/// Capability 请求路径，而不会触发真实 HTTPS 绑定或 TLS 证书生成。
final class FakeLanTransferService extends Fake implements LanTransferService {
  final StreamController<LanPairingRequest> _pairingInviteController =
      StreamController<LanPairingRequest>.broadcast();
  final StreamController<LanDevice> _announcedDeviceController =
      StreamController<LanDevice>.broadcast();
  final StreamController<LanDevice> _handshakePendingController =
      StreamController<LanDevice>.broadcast();
  int _port = LanTransferService.defaultHttpPort;
  bool _listening = false;
  int stopListeningCalls = 0;
  bool disposed = false;

  @override
  Stream<LanPairingRequest> get pairingInviteStream =>
      _pairingInviteController.stream;

  @override
  Stream<LanDevice> get announcedDeviceStream =>
      _announcedDeviceController.stream;

  @override
  Stream<LanDevice> get handshakePendingStream =>
      _handshakePendingController.stream;

  @override
  bool get isListening => _listening;

  @override
  int get activePort => _port;

  @override
  Future<NetworkResult<int>> startListening({
    int port = LanTransferService.defaultHttpPort,
  }) async {
    _listening = true;
    _port = port;
    return NetworkSuccess<int>(port);
  }

  @override
  Future<NetworkResult<void>> stopListening() async {
    _listening = false;
    stopListeningCalls++;
    return const NetworkSuccess<void>(null);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

final class FakeLanStorageService extends Fake implements LanStorageService {}

final class FakeLanHistoryDao extends Fake implements LanHistoryDao {}
