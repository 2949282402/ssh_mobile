import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  test('LanDevice preserves the independent native transfer port', () {
    final device = LanDevice(
      id: 'peer-1',
      alias: 'Peer 1',
      ip: '192.168.1.5',
      port: 5432,
      nativePort: 6543,
      deviceType: LanDeviceType.mobile,
      osName: 'android',
      lastSeen: DateTime.utc(2026, 8, 25),
    );

    final decoded = LanDevice.fromJson(device.toJson());

    expect(decoded.port, 5432);
    expect(decoded.nativePort, 6543);
  });

  test('LanShareViewModel forgetDevice clears the paired device', () async {
    final security = FakeLanSecurityService();
    final settings = FakeLanShareSettings();
    final viewModel = LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: security,
      storageService: FakeLanStorageService(),
      transferService: FakeLanTransferService(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );

    await viewModel.forgetDevice('test-device-id');

    expect(security.unpairedDeviceId, 'test-device-id');
    viewModel.dispose();
    settings.dispose();
  });

  test(
    'sendFile routes through explicit register + connect + transfer',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lan-share-facade-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.txt');
      await file.writeAsString('payload');

      final facade = FakeLanShareNetworkService();
      final security = _PinnedKeySecurityService();
      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );
      final httpOverrides = _CapabilityHttpOverrides([6543, 6544]);
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        networkFacade: facade,
        historyDao: _StubHistoryDao(),
        appSettings: FakeLanShareSettings(),
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      final results = await HttpOverrides.runWithHttpOverrides(() async {
        final firstResult = await viewModel.sendFile(
          LanDevice(
            id: 'peer-1',
            alias: 'Peer 1',
            ip: '192.168.1.5',
            port: 5432,
            nativePort: 6543,
            deviceType: LanDeviceType.mobile,
            osName: 'android',
            lastSeen: DateTime.now(),
          ),
          file.path,
        );
        final secondResult = await viewModel.sendFile(
          LanDevice(
            id: 'peer-1',
            alias: 'Peer 1',
            ip: '192.168.1.5',
            port: 5432,
            deviceType: LanDeviceType.mobile,
            osName: 'android',
            lastSeen: DateTime.now(),
          ),
          file.path,
        );
        return (firstResult, secondResult);
      }, httpOverrides);

      expect(results.$1, isA<SdkSuccess<SdkTransferSession>>());
      expect(results.$2, isA<SdkSuccess<SdkTransferSession>>());
      expect(httpOverrides.capabilityRequests, 2);
      expect(facade.registerPeerCalls, 2);
      expect(facade.connectPeerCalls, 2);
      expect(
        facade.lastRegisteredPeerConfig?.endpointAddress,
        '192.168.1.5:6544',
      );
      expect(facade.transferFileCalls, 2);
      viewModel.dispose();
      await transfer.close();
    },
  );

  test(
    'text and clipboard fail closed when E2E capability is absent',
    () async {
      final security = _MissingKeySecurityService();
      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );
      final settings = FakeLanShareSettings();
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        historyDao: _StubHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );
      final device = LanDevice(
        id: 'peer-1',
        alias: 'Peer 1',
        ip: '192.168.1.5',
        port: 5432,
        deviceType: LanDeviceType.mobile,
        osName: 'android',
        lastSeen: DateTime.now(),
      );

      final results = await HttpOverrides.runWithHttpOverrides(
        () async => (
          await viewModel.sendText(device, 'hello'),
          await viewModel.sendClipboard(device, 'clipboard'),
        ),
        _StaticJsonHttpOverrides(<String, dynamic>{'e2eEncryption': false}),
      );
      expect(results.$1, isA<NetworkFailure<void>>());
      expect(
        (results.$1 as NetworkFailure<void>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(results.$2, isA<NetworkFailure<void>>());

      viewModel.dispose();
      settings.dispose();
      await transfer.close();
    },
  );

  test('invalid native capability ports never register or connect', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lan-share-invalid-capability-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/payload.bin');
    await file.writeAsBytes(<int>[1]);
    final facade = FakeLanShareNetworkService();
    final security = _PinnedKeySecurityService();
    final transfer = LanTransferService(
      currentDeviceId: 'sender-1',
      securityService: security,
      storageService: FakeLanStorageService(),
    );
    final settings = FakeLanShareSettings();
    final viewModel = LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: security,
      storageService: FakeLanStorageService(),
      transferService: transfer,
      networkFacade: facade,
      historyDao: _StubHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    final encodedKey = base64.encode(_PinnedKeySecurityService._key);
    final bodies = <Map<String, dynamic>>[
      {
        'e2eEncryption': true,
        'x25519PubKey': encodedKey,
        'networkIdentityPubKey': encodedKey,
        'quicFileTransfer': false,
        'quicPort': 43123,
      },
      for (final port in <int?>[0, 65536, null])
        {
          'e2eEncryption': true,
          'x25519PubKey': encodedKey,
          'networkIdentityPubKey': encodedKey,
          'quicFileTransfer': true,
          'quicPort': port,
        },
    ];

    final results = await HttpOverrides.runWithHttpOverrides(() async {
      final values = <NetworkResult<TransferSession>>[];
      for (var index = 0; index < bodies.length; index++) {
        values.add(
          await viewModel.sendFile(
            LanDevice(
              id: 'peer-$index',
              alias: 'Peer $index',
              ip: '192.168.1.${index + 2}',
              port: 5432,
              deviceType: LanDeviceType.mobile,
              osName: 'android',
              lastSeen: DateTime.now(),
            ),
            file.path,
          ),
        );
      }
      return values;
    }, _CapabilityBodiesHttpOverrides(bodies));

    expect(results, everyElement(isA<NetworkFailure<TransferSession>>()));
    expect(
      results.map((result) => (result as NetworkFailure).error.code),
      everyElement(NetworkErrorCode.noRoute),
    );
    expect(facade.registerPeerCalls, 0);
    expect(facade.connectPeerCalls, 0);

    viewModel.dispose();
    settings.dispose();
    await transfer.close();
  });

  test(
    'changed paired identity fails closed without native registration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lan-share-identity-conflict-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.bin');
      await file.writeAsBytes(<int>[1]);
      final facade = FakeLanShareNetworkService();
      final security = _PinnedKeySecurityService();
      final transfer = LanTransferService(
        currentDeviceId: 'sender-1',
        securityService: security,
        storageService: FakeLanStorageService(),
      );
      final settings = FakeLanShareSettings();
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: transfer,
        networkFacade: facade,
        historyDao: _StubHistoryDao(),
        appSettings: settings,
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );
      final changedKey = base64.encode(List<int>.filled(32, 9));
      final result = await HttpOverrides.runWithHttpOverrides(
        () => viewModel.sendFile(
          LanDevice(
            id: 'peer-1',
            alias: 'Peer 1',
            ip: '192.168.1.2',
            port: 5432,
            deviceType: LanDeviceType.mobile,
            osName: 'android',
            lastSeen: DateTime.now(),
          ),
          file.path,
        ),
        _StaticJsonHttpOverrides(<String, dynamic>{
          'e2eEncryption': true,
          'x25519PubKey': changedKey,
          'networkIdentityPubKey': changedKey,
          'quicFileTransfer': true,
          'quicPort': 43123,
        }),
      );

      expect(result, isA<NetworkFailure<TransferSession>>());
      expect(
        (result as NetworkFailure<TransferSession>).error.code,
        NetworkErrorCode.identityConflict,
      );
      expect(facade.registerPeerCalls, 0);
      expect(facade.connectPeerCalls, 0);

      viewModel.dispose();
      settings.dispose();
      await transfer.close();
    },
  );
}

final class _MissingKeySecurityService extends Fake
    implements LanSecurityService {
  @override
  Future<Uint8List?> getPeerX25519PublicKey(String deviceId) async => null;

  @override
  Future<Uint8List?> getPeerNetworkIdentityPublicKey(String deviceId) async =>
      null;

  @override
  Future<String?> getPeerCertificateFingerprint(String deviceId) async => null;

  @override
  Future<String?> getOutboundAccessToken(String deviceId) async => 'token';

  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => true;
}

/// 返回 32 字节固定身份密钥的安全服务，让 sendFile 直接命中已配对路径，
/// 不触发真实 LAN HTTPS 能力查询。
final class _PinnedKeySecurityService extends Fake
    implements LanSecurityService {
  static final Uint8List _key = Uint8List.fromList(
    List<int>.generate(32, (index) => index + 1),
  );

  @override
  Future<Uint8List?> getPeerX25519PublicKey(String deviceId) async => _key;

  @override
  Future<Uint8List?> getPeerNetworkIdentityPublicKey(String deviceId) async =>
      _key;

  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => false;

  @override
  Future<String?> getOutboundAccessToken(String deviceId) async => 'token';

  @override
  Future<String?> getPeerCertificateFingerprint(String deviceId) async => null;
}

final class _CapabilityHttpOverrides extends HttpOverrides {
  _CapabilityHttpOverrides(this._ports);

  static final String _encodedKey = base64.encode(
    List<int>.generate(32, (index) => index + 1),
  );

  final List<int> _ports;
  int capabilityRequests = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final port = _ports[capabilityRequests++];
    return _JsonHttpClient(<String, dynamic>{
      'e2eEncryption': true,
      'x25519PubKey': _encodedKey,
      'networkIdentityPubKey': _encodedKey,
      'quicFileTransfer': true,
      'quicPort': port,
      'maxEncryptedFileBytes': 1024 * 1024,
    });
  }
}

final class _StaticJsonHttpOverrides extends HttpOverrides {
  _StaticJsonHttpOverrides(this.body);

  final Map<String, dynamic> body;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _JsonHttpClient(body);
}

final class _CapabilityBodiesHttpOverrides extends HttpOverrides {
  _CapabilityBodiesHttpOverrides(this.bodies);

  final List<Map<String, dynamic>> bodies;
  int requestCount = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _JsonHttpClient(bodies[requestCount++]);
}

final class _JsonHttpClient extends Fake implements HttpClient {
  _JsonHttpClient(this.body);

  final Map<String, dynamic> body;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  String Function(Uri)? findProxy;

  @override
  bool Function(X509Certificate cert, String host, int port)?
  badCertificateCallback;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _JsonHttpClientRequest(body);

  @override
  void close({bool force = false}) {}
}

final class _JsonHttpClientRequest extends Fake implements HttpClientRequest {
  _JsonHttpClientRequest(this.body);

  final Map<String, dynamic> body;
  final HttpHeaders _headers = _FakeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _JsonHttpClientResponse(body);
}

final class _FakeHttpHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

final class _JsonHttpClientResponse extends Fake implements HttpClientResponse {
  _JsonHttpClientResponse(Map<String, dynamic> body)
    : _bytes = utf8.encode(jsonEncode(body));

  final List<int> _bytes;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  Future<void> forEach(void Function(List<int> element) action) =>
      Stream<List<int>>.value(_bytes).forEach(action);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

/// 记录 sendFile 写入路径的最小历史 DAO 替身；`Fake` 对非空 Future 返回类型
/// 会抛 `UnimplementedError`，因此只覆盖 sendFile 用到的两个方法。
final class _StubHistoryDao extends Fake implements LanHistoryDao {
  @override
  Future<int> insertRecord(LanTransferRecordsCompanion record) async => 1;

  @override
  Future<bool> updateRecordStatus(
    String id,
    String status, {
    int? bytesTransferred,
    bool? isRecalled,
    String? localPath,
    String? transport,
    String? routeType,
    int? avgRtt,
    int? bytesTotal,
    String? failureReason,
  }) async => true;
}
