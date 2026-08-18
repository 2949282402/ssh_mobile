import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
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
    'sendFile routes through the NetworkFacade connect + transfer path',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lan-share-facade-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.txt');
      await file.writeAsString('payload');

      final facade = FakeLanShareNetworkService();
      final security = _PinnedKeySecurityService();
      final viewModel = LanShareViewModel(
        discoveryService: FakeLanDiscoveryService(),
        securityService: security,
        storageService: FakeLanStorageService(),
        transferService: FakeLanTransferService(),
        networkFacade: facade,
        historyDao: _StubHistoryDao(),
        appSettings: FakeLanShareSettings(),
        dataProtection: FakeLanShareDataProtection(),
        logger: FakeLanShareLogger(),
        ownsRuntime: false,
      );

      final result = await viewModel.sendFile(
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

      expect(result, isA<SdkSuccess<SdkTransferSession>>());
      expect(facade.connectPeerCalls, 1);
      expect(facade.transferFileCalls, 1);
      viewModel.dispose();
    },
  );
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
