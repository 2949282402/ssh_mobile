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
  FakeLanShareSettings({this.english = false});

  final bool english;
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
  String get relayEndpoint => '';

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
  int createCalls = 0;

  @override
  Future<NetworkService?> create({
    required String deviceId,
    required Uint8List identityPrivateKey,
    required Uint8List e2ePrivateKey,
    required String listenAddress,
    required String receiveDirectory,
  }) async {
    createCalls++;
    return null;
  }
}

final class FakeLanShareNetworkRuntime implements NetworkRuntime {
  int ensureCalls = 0;
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
  }

  @override
  Future<NetworkCommandGateway> openCommandGateway() async =>
      throw UnsupportedError('fake runtime has no command gateway');

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

final class FakeLanShareBootstrapClient implements BootstrapClient {
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

final class FakeLanTransferService extends Fake implements LanTransferService {}

final class FakeLanStorageService extends Fake implements LanStorageService {}

final class FakeLanHistoryDao extends Fake implements LanHistoryDao {}
