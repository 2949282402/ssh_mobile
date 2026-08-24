// v1 LAN 已配对设备缓存与凭据生命周期操作。
//
// 这些方法仍属于 LanSecurityService 所在 library，但通过独立 extension 拆分，
// 使安全服务保持在 1000 行限制以内。

part of 'lan_security_service.dart';

/// 为 [LanSecurityService] 添加已配对设备持久化操作。
extension LanSecurityPairingOperations on LanSecurityService {
  /// 清除内存配对设备缓存，使下一次读取重新加载数据。
  void _invalidatePairedCache() {
    _pairingStateGeneration++;
    _pairedCache = null;
    _pairedCacheLoadFuture = null;
  }

  /// 合并并发的首次配对缓存加载。
  Future<void> _ensurePairedCacheLoaded() async {
    while (_pairedCache == null) {
      var activeLoad = _pairedCacheLoadFuture;
      if (activeLoad == null) {
        final generation = _pairingStateGeneration;
        late final Future<void> load;
        load =
            (() async {
              final loaded = await _readPairedCacheFromDisk();
              if (_pairedCache == null &&
                  generation == _pairingStateGeneration) {
                _pairedCache = loaded;
              }
            })().whenComplete(() {
              if (identical(_pairedCacheLoadFuture, load)) {
                _pairedCacheLoadFuture = null;
              }
            });
        _pairedCacheLoadFuture = load;
        activeLoad = load;
      }
      await activeLoad;
    }
  }

  /// 持久化最新配对快照；若等待写入期间状态变化则重写。
  ///
  /// 这使多个安全存储写入即使乱序完成，最终也不会恢复过期状态。
  Future<void> _persistLatestPairedCache() async {
    while (true) {
      final generation = _pairingStateGeneration;
      final snapshot = jsonEncode(_pairedCache ?? const <String, int>{});
      await _secureStorage.write(
        key: LanSecurityService._pairedDevicesStorageKey,
        value: snapshot,
      );
      if (generation == _pairingStateGeneration) return;
    }
  }

  /// 从安全存储加载配对设备时间戳，并兼容已有列表数据。
  Future<Map<String, int>> _readPairedCacheFromDisk() async {
    final rawList = await _secureStorage.read(
      key: LanSecurityService._pairedDevicesStorageKey,
    );
    if (rawList == null) {
      return {};
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
    return result;
  }

  /// 持久化远端设备的临时配对。
  Future<void> _pairDevice(String deviceId) async {
    await _ensurePairedCacheLoaded();
    final cache = _pairedCache!;
    cache[deviceId] = DateTime.now().millisecondsSinceEpoch;
    _pairingStateGeneration++;
    await _persistLatestPairedCache();
  }

  /// 相互 PIN 校验成功后持久化永久配对。
  Future<void> _confirmDevicePairing(String deviceId) async {
    await _ensurePairedCacheLoaded();
    final cache = _pairedCache!;
    cache[deviceId] = 0;
    _pairingStateGeneration++;
    await _persistLatestPairedCache();
  }

  /// 移除全部配对设备记录及其安全凭据。
  Future<void> _unpairAllDevices() async {
    await _ensurePairedCacheLoaded();
    _pairedCache = {};
    _pairingStateGeneration++;
    _lastCheckTime.clear();
    _inboundAccessTokenCache = {};
    _outboundAccessTokenCache = {};
    _freshOutboundPinProofExpiry.clear();
    await Future.wait([
      _persistLatestPairedCache(),
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

  /// 检查远端设备是否已配对，并按需重新验证。
  Future<bool> _isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async {
    await _ensurePairedCacheLoaded();
    final cache = _pairedCache!;
    final timestamp = cache[deviceId];
    final generation = _pairingStateGeneration;
    if (timestamp == null) {
      return false;
    }
    final hasToken = await hasOutboundAccessToken(deviceId);
    final hasFingerprint = await hasPeerCertificateFingerprint(deviceId);
    // Secure-storage reads yield to concurrent unpair operations. Revalidate
    // the exact cache generation before publishing a positive answer.
    if (!hasToken ||
        !hasFingerprint ||
        generation != _pairingStateGeneration ||
        !identical(_pairedCache, cache) ||
        cache[deviceId] != timestamp) {
      return false;
    }

    if (timestamp == 0) return true;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - timestamp > 60000) {
      cache.remove(deviceId);
      _pairingStateGeneration++;
      await _persistLatestPairedCache();
      return false;
    }

    if (ip != null && port != null && localDeviceId != null) {
      final lastCheck = _lastCheckTime[deviceId];
      if (lastCheck == null ||
          DateTime.now().difference(lastCheck).inSeconds > 5) {
        _lastCheckTime[deviceId] = DateTime.now();
        final revalidationGeneration = _pairingStateGeneration;
        unawaited(
          _revalidateTemporaryPairing(
            deviceId: deviceId,
            ip: ip,
            port: port,
            localDeviceId: localDeviceId,
            expectedTimestamp: timestamp,
            expectedGeneration: revalidationGeneration,
            expectedCache: cache,
          ),
        );
      }
    }
    return true;
  }

  /// 移除远端设备及绑定到该设备的全部凭据。
  Future<void> _unpairDevice(String deviceId) async {
    await _ensurePairedCacheLoaded();
    final cache = _pairedCache!;
    cache.remove(deviceId);
    _pairingStateGeneration++;
    _lastCheckTime.remove(deviceId);
    // 持久配对记录与各凭据独立清理并全部等待；单一存储失败不能跳过
    // 其它 fail-closed 撤销屏障。
    await Future.wait([
      _persistLatestPairedCache(),
      _removePairAccessTokens(deviceId),
      _removePeerX25519PublicKey(deviceId),
      _removePeerNetworkIdentityPublicKey(deviceId),
    ]);
  }

  /// 在后台复查临时配对，并仅在原快照仍有效时升级。
  Future<void> _revalidateTemporaryPairing({
    required String deviceId,
    required String ip,
    required int port,
    required String localDeviceId,
    required int expectedTimestamp,
    required int expectedGeneration,
    required Map<String, int> expectedCache,
  }) async {
    try {
      final expectedFingerprint = await getPeerCertificateFingerprint(deviceId);
      final token = await getOutboundAccessToken(deviceId);
      if (expectedFingerprint == null || token == null || token.isEmpty) return;
      final endpoint = Uri(
        scheme: 'https',
        host: ip,
        port: port,
        path: '/api/lan/check_pair',
        queryParameters: {'deviceId': localDeviceId},
      );
      final verifier = remotePairVerifier ?? _verifyRemotePairStatus;
      final paired = await verifier(
        endpoint: endpoint,
        accessToken: token,
        expectedFingerprint: expectedFingerprint,
      );
      if (!paired ||
          _pairingStateGeneration != expectedGeneration ||
          !identical(_pairedCache, expectedCache) ||
          expectedCache[deviceId] != expectedTimestamp) {
        return;
      }
      expectedCache[deviceId] = 0;
      _pairingStateGeneration++;
      await _persistLatestPairedCache();
    } catch (_) {}
  }

  /// 使用证书指纹固定发起有界的远程配对查询。
  Future<bool> _verifyRemotePairStatus({
    required Uri endpoint,
    required String accessToken,
    required String expectedFingerprint,
  }) async {
    const maxResponseBytes = 64 * 1024;
    final normalizedFingerprint = expectedFingerprint.toLowerCase();
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 2)
      ..idleTimeout = const Duration(seconds: 2)
      ..findProxy = ((_) => 'DIRECT')
      ..badCertificateCallback = (cert, host, port) {
        return _certificateFingerprintFromDer(cert.der) ==
            normalizedFingerprint;
      };
    try {
      final request = await client
          .getUrl(endpoint)
          .timeout(const Duration(seconds: 2));
      request.followRedirects = false;
      final localDeviceId = endpoint.queryParameters['deviceId'];
      if (localDeviceId == null || localDeviceId.isEmpty) return false;
      request.headers.set('x-device-id', localDeviceId);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > maxResponseBytes) {
        return false;
      }
      final bytes = await (() async {
        final body = BytesBuilder(copy: false);
        var total = 0;
        await for (final chunk in response.timeout(
          const Duration(seconds: 2),
        )) {
          total += chunk.length;
          if (total > maxResponseBytes) return null;
          body.add(chunk);
        }
        return body;
      })().timeout(const Duration(seconds: 2));
      if (bytes == null) return false;
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      return decoded is Map<String, dynamic> && decoded['paired'] == true;
    } finally {
      client.close(force: true);
    }
  }

  /// 计算 TLS 回调使用的同步证书指纹。
  String _certificateFingerprintFromDer(Uint8List der) {
    return crypto.sha256.convert(der).toString();
  }

  /// 返回本设备用于 LAN v1 配对的证书指纹。
  Future<String> _getLocalCertificateFingerprint(String deviceId) async {
    await getOrCreateSecurityContext(deviceId);
    final pem = _cachedCertPem;
    if (pem == null) throw StateError('LAN certificate is unavailable.');
    return computeCertFingerprint(pem);
  }
}
