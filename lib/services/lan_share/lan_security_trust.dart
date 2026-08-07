// v1 LAN 远端证书指纹信任存储扩展。
//
// 该文件通过 extension 拆分 LanSecurityService 的 TOFU 操作，
// 保持安全服务主文件在 1000 行限制以内。

part of 'lan_security_service.dart';

/// 为 [LanSecurityService] 提供远端证书指纹信任操作。
extension LanSecurityTrustOperations on LanSecurityService {
  /// 检查远端设备证书指纹是否可信（TOFU）。
  Future<bool> isDeviceTrusted(String certFingerprint) async {
    final rawList = await _secureStorage.read(
      key: LanSecurityService._trustedDevicesStorageKey,
    );
    if (rawList == null) return false;
    try {
      final List<dynamic> list = jsonDecode(rawList);
      return list.contains(certFingerprint);
    } catch (_) {
      return false;
    }
  }

  /// 信任远端设备的证书指纹。
  Future<void> trustDevice(String certFingerprint) async {
    final rawList = await _secureStorage.read(
      key: LanSecurityService._trustedDevicesStorageKey,
    );
    final Set<String> trustedSet = {};
    if (rawList != null) {
      try {
        final List<dynamic> list = jsonDecode(rawList);
        trustedSet.addAll(list.cast<String>());
      } catch (_) {}
    }
    trustedSet.add(certFingerprint);
    await _secureStorage.write(
      key: LanSecurityService._trustedDevicesStorageKey,
      value: jsonEncode(trustedSet.toList()),
    );
  }

  /// 忘记一个可信设备。
  Future<void> untrustDevice(String certFingerprint) async {
    final rawList = await _secureStorage.read(
      key: LanSecurityService._trustedDevicesStorageKey,
    );
    if (rawList == null) return;
    try {
      final List<dynamic> list = jsonDecode(rawList);
      final Set<String> trustedSet = list.cast<String>().toSet();
      trustedSet.remove(certFingerprint);
      await _secureStorage.write(
        key: LanSecurityService._trustedDevicesStorageKey,
        value: jsonEncode(trustedSet.toList()),
      );
    } catch (_) {}
  }
}
