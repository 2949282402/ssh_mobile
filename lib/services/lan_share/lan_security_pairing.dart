// v1 LAN 已配对设备缓存与凭据生命周期操作。
//
// 这些方法仍属于 LanSecurityService 所在 library，但通过独立 extension 拆分，
// 使安全服务保持在 1000 行限制以内。

part of 'lan_security_service.dart';

/// 为 [LanSecurityService] 添加已配对设备持久化操作。
extension LanSecurityPairingOperations on LanSecurityService {
  /// 清除内存配对设备缓存，使下一次读取重新加载数据。
  void invalidatePairedCache() => _pairedCache = null;

  /// 从安全存储加载配对设备时间戳，并兼容已有列表数据。
  Future<void> _loadPairedCacheFromDisk() async {
    final rawList = await _secureStorage.read(
      key: LanSecurityService._pairedDevicesStorageKey,
    );
    if (rawList == null) {
      _pairedCache = {};
      return;
    }
    final Map<String, int> result = {};
    try {
      final Map<String, dynamic> decoded = jsonDecode(rawList);
      result.addAll(decoded.map((key, value) => MapEntry(key, value as int)));
    } catch (_) {
      try {
        final List<dynamic> list = jsonDecode(rawList);
        for (final id in list) {
          result[id as String] = 0;
        }
      } catch (_) {}
    }
    _pairedCache = result;
  }

  /// 持久化远端设备的临时配对。
  Future<void> pairDevice(String deviceId) async {
    if (_pairedCache == null) await _loadPairedCacheFromDisk();
    final cache = _pairedCache!;
    cache[deviceId] = DateTime.now().millisecondsSinceEpoch;
    await _secureStorage.write(
      key: LanSecurityService._pairedDevicesStorageKey,
      value: jsonEncode(cache),
    );
  }

  /// 相互 PIN 校验成功后持久化永久配对。
  Future<void> confirmDevicePairing(String deviceId) async {
    if (_pairedCache == null) await _loadPairedCacheFromDisk();
    final cache = _pairedCache!;
    cache[deviceId] = 0;
    await _secureStorage.write(
      key: LanSecurityService._pairedDevicesStorageKey,
      value: jsonEncode(cache),
    );
  }

  /// 移除全部配对设备记录及其安全凭据。
  Future<void> unpairAllDevices() async {
    _pairedCache = {};
    _inboundAccessTokenCache = {};
    _outboundAccessTokenCache = {};
    _freshOutboundPinProofExpiry.clear();
    await Future.wait([
      _secureStorage.delete(key: LanSecurityService._pairedDevicesStorageKey),
      _secureStorage.delete(
        key: LanSecurityService._inboundAccessTokensStorageKey,
      ),
      _secureStorage.delete(
        key: LanSecurityService._outboundAccessTokensStorageKey,
      ),
      _secureStorage.delete(
        key: LanSecurityService._peerCertificateFingerprintsStorageKey,
      ),
      _secureStorage.delete(key: LanSecurityService._peerX25519KeysStorageKey),
      _secureStorage.delete(
        key: LanSecurityService._peerNetworkIdentityKeysStorageKey,
      ),
    ]);
  }

  /// 返回本设备用于 LAN 配对的证书指纹。
  Future<String> getLocalCertificateFingerprint(String deviceId) async {
    await getOrCreateSecurityContext(deviceId);
    final pem = _cachedCertPem;
    if (pem == null) throw StateError('LAN certificate is unavailable.');
    return computeCertFingerprint(pem);
  }
}
