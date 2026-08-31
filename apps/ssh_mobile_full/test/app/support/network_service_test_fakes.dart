// Network V2 身份 / 数据保护 / Facade 共享测试替身。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart' as sdk;
import 'package:ssh_mobile/core/services/data_protection_service.dart';
import 'package:ssh_mobile/services/network/network_identity_service.dart';

/// 返回固定身份的 Network V2 身份 Service 替身。
final class FakeNetworkIdentityService extends Fake
    implements NetworkIdentityService {
  FakeNetworkIdentityService({NetworkIdentityBundle? bundle})
    : result =
          bundle ??
          NetworkIdentityBundle(
            ed25519PrivateSeed: Uint8List.fromList(<int>[1]),
            ed25519PublicKey: Uint8List.fromList(<int>[2]),
            x25519PrivateSeed: Uint8List.fromList(<int>[3]),
            x25519PublicKey: Uint8List.fromList(<int>[4]),
          );

  final NetworkIdentityBundle result;
  int loadCalls = 0;

  @override
  Future<NetworkIdentityBundle> loadOrCreate() async {
    loadCalls++;
    return result;
  }
}

/// 固定加密结果的 Data Protection Service 替身。
final class FakeDataProtectionService extends Fake
    implements DataProtectionService {
  int encryptCalls = 0;
  int decryptCalls = 0;
  int isEncryptedCalls = 0;

  @override
  Future<String> encryptString(String value) async {
    encryptCalls++;
    return 'ssh-mobile-v1:$value';
  }

  @override
  Future<String> decryptString(String value) async {
    decryptCalls++;
    return value.startsWith('ssh-mobile-v1:')
        ? value.substring('ssh-mobile-v1:'.length)
        : value;
  }

  @override
  bool isEncrypted(String value) {
    isEncryptedCalls++;
    return value.startsWith('ssh-mobile-v1:');
  }
}

/// 只借用 Facade 的 NetworkAccess 测试用 Facade 替身。
final class FakeNetworkFacade extends Fake implements sdk.NetworkFacade {}
