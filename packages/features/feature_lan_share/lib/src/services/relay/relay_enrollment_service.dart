// v1 Relay enrollment 与原生凭据桥接；Dart 不承载 Relay 数据面。

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:network_sdk/network_sdk.dart';

/// 标识用于 enrollment 和原生配置的 Relay 源站。
final class RelaySettings {
  /// 为一个 HTTPS Relay 源站创建配置。
  const RelaySettings({required this.endpoint});

  /// 不包含路径、查询参数或凭据的 Relay HTTPS 源站。
  final Uri endpoint;
}

/// 只包含 Rust Relay 客户端所需的凭据材料。
final class RelayNativeConfiguration {
  /// 创建原生 Relay 配置快照。
  const RelayNativeConfiguration({
    required this.endpoint,
    required this.credential,
    required this.signingSeed,
  });

  /// 传递给原生运行时的 Relay 源站。
  final Uri endpoint;

  /// 短期 enrollment 凭据。
  final String credential;

  /// 从安全存储加载的 Ed25519 签名种子。
  final Uint8List signingSeed;
}

/// 负责 Dart 层的 Relay enrollment 与安全凭据读取。
final class RelayEnrollmentService {
  /// 为一个稳定设备身份创建 enrollment 服务。
  RelayEnrollmentService({
    required this.currentDeviceId,
    required this._bootstrapClient,
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           );

  /// 绑定在 enrollment 凭据中的当前设备标识。
  final String currentDeviceId;
  final FlutterSecureStorage _secureStorage;
  final BootstrapClient _bootstrapClient;

  /// Go 与 Rust Relay 共享的当前开发线协议版本。
  static const int protocolVersion = 1;

  /// 为设备执行 enrollment，并将凭据写入安全存储。
  ///
  /// 可预期的端点、认证、响应和 I/O 失败都通过 [NetworkFailure] 返回。
  Future<NetworkResult<void>> enroll(
    RelaySettings settings,
    String enrollmentToken,
  ) async {
    late final Uri endpoint;
    try {
      endpoint = _validatedEndpoint(settings.endpoint);
    } on ArgumentError {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Relay enrollment endpoint is invalid.',
      );
    }
    if (currentDeviceId.isEmpty || currentDeviceId.length > 128) {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Relay device identity is invalid.',
      );
    }
    if (enrollmentToken.length < 16) {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Relay enrollment token is invalid.',
      );
    }
    try {
      final pair = await _signingKeyPair();
      final publicKey = await pair.extractPublicKey();
      final enrollment = await _bootstrapClient.enroll(
        endpoint,
        EnrollmentRequest(
          deviceId: currentDeviceId,
          identityPublicKey: Uint8List.fromList(publicKey.bytes),
          enrollmentToken: enrollmentToken,
          protocolVersion: protocolVersion,
          platform: Platform.operatingSystem,
        ),
      );
      if (enrollment is SdkFailure<DeviceEnrollment>) {
        return NetworkFailure<void>(enrollment.error);
      }
      final data = (enrollment as SdkSuccess<DeviceEnrollment>).data;
      if (data.protocolVersion != protocolVersion) {
        return _failure(
          code: NetworkErrorCode.relayError,
          message: 'Relay enrollment protocol version is unsupported.',
        );
      }
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final localExpiresAt =
          nowSeconds + data.expiresAt.difference(data.serverTime).inSeconds;
      await _secureStorage.write(
        key: _credentialKey,
        value: jsonEncode({
          'endpoint': _credentialEndpoint(endpoint),
          'device_id': currentDeviceId,
          'credential': data.relayCredential,
          'expires_at': localExpiresAt,
          'protocol_version': data.protocolVersion,
        }),
      );
      return const NetworkSuccess<void>(null);
    } on Object {
      return _failure(
        code: NetworkErrorCode.relayError,
        message: 'Relay enrollment failed.',
      );
    }
  }

  /// 为已 enrollment 设备签发新的短期凭据，无需 enrollment token。
  ///
  /// 使用设备签名种子对 refresh 请求签名；成功后以与 [enroll] 相同的安全存储
  /// 写入形状保存新凭据。失败时以 [NetworkFailure] 返回；404 被 SDK 映射为
  /// [NetworkErrorCode.noRoute]，表示设备未 enrollment，需要重新 enroll。
  Future<NetworkResult<void>> refreshCredential(RelaySettings settings) async {
    late final Uri endpoint;
    try {
      endpoint = _validatedEndpoint(settings.endpoint);
    } on ArgumentError {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Relay refresh endpoint is invalid.',
      );
    }
    if (currentDeviceId.isEmpty || currentDeviceId.length > 128) {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Relay device identity is invalid.',
      );
    }
    try {
      final pair = await _signingKeyPair();
      final publicKey = await pair.extractPublicKey();
      final nonce = _randomRefreshNonce();
      final transcript = 'POST\n/v1/devices/refresh\n$nonce';
      final signatureBytes = (await Ed25519().sign(
        utf8.encode(transcript),
        keyPair: pair,
      )).bytes;
      final refresh = await _bootstrapClient.refresh(
        endpoint,
        RefreshRequest(
          deviceId: currentDeviceId,
          identityPublicKey: Uint8List.fromList(publicKey.bytes),
          nonce: nonce,
          signature: base64UrlEncode(signatureBytes).replaceAll('=', ''),
        ),
      );
      if (refresh is SdkFailure<DeviceEnrollment>) {
        return NetworkFailure<void>(refresh.error);
      }
      final data = (refresh as SdkSuccess<DeviceEnrollment>).data;
      if (data.protocolVersion != protocolVersion) {
        return _failure(
          code: NetworkErrorCode.relayError,
          message: 'Relay refresh protocol version is unsupported.',
        );
      }
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final localExpiresAt =
          nowSeconds + data.expiresAt.difference(data.serverTime).inSeconds;
      await _secureStorage.write(
        key: _credentialKey,
        value: jsonEncode({
          'endpoint': _credentialEndpoint(endpoint),
          'device_id': currentDeviceId,
          'credential': data.relayCredential,
          'expires_at': localExpiresAt,
          'protocol_version': data.protocolVersion,
        }),
      );
      return const NetworkSuccess<void>(null);
    } on Object {
      return _failure(
        code: NetworkErrorCode.relayError,
        message: 'Relay credential refresh failed.',
      );
    }
  }

  /// 当前端点和设备是否保存过 enrollment 凭据记录（无论是否已过期）。
  Future<bool> hasStoredCredential(RelaySettings settings) async {
    final endpoint = _validatedEndpoint(settings.endpoint);
    final stored = await _secureStorage.read(key: _credentialKey);
    if (stored == null || stored.isEmpty) return false;
    try {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      return decoded['endpoint'] == _credentialEndpoint(endpoint) &&
          decoded['device_id'] == currentDeviceId;
    } on Object {
      return false;
    }
  }

  /// 仅当当前端点和设备范围内存在有效凭据时返回 true。
  Future<bool> isEnrolled(RelaySettings settings) async =>
      (await _credentialFor(settings)) != null;

  /// 加载仅供原生使用的身份材料，不将其暴露到 Dart 数据流。
  Future<RelayNativeConfiguration?> nativeConfiguration(
    RelaySettings settings,
  ) async {
    final endpoint = _validatedEndpoint(settings.endpoint);
    final credential = await _credentialFor(RelaySettings(endpoint: endpoint));
    if (credential == null) return null;
    return RelayNativeConfiguration(
      endpoint: endpoint,
      credential: credential,
      signingSeed: Uint8List.fromList(
        await (await _signingKeyPair()).extractPrivateKeyBytes(),
      ),
    );
  }

  /// 清除当前设备的 Relay enrollment 凭据，但保留设备签名种子。
  ///
  /// 签名种子代表设备身份，不应因为更换 Relay 源站或用户主动清除
  /// enrollment 而轮换；短期 Relay credential 则必须立即从安全存储移除。
  Future<void> clearEnrollment() => _secureStorage.delete(key: _credentialKey);

  /// Dart 不承载 Relay 数据面，因此此处不释放 socket。
  Future<void> dispose() async {}

  static const _credentialKey = 'relay_device_credential_v1';
  static const _signingSeedKey = 'relay_device_signing_seed_v1';

  /// 读取并校验端点、设备、协议版本和过期时间绑定。
  Future<String?> _credentialFor(RelaySettings settings) async {
    final stored = await _secureStorage.read(key: _credentialKey);
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      if (decoded['endpoint'] != _credentialEndpoint(settings.endpoint) ||
          decoded['device_id'] != currentDeviceId ||
          decoded['protocol_version'] != protocolVersion) {
        return null;
      }
      final expiresAt = (decoded['expires_at'] as num?)?.toInt();
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (expiresAt == null || expiresAt <= nowSeconds) return null;
      final credential = decoded['credential'] as String?;
      return credential == null || credential.isEmpty ? null : credential;
    } on Object {
      return null;
    }
  }

  /// 从安全存储加载或创建 Ed25519 签名种子。
  Future<SimpleKeyPair> _signingKeyPair() async {
    final stored = await _secureStorage.read(key: _signingSeedKey);
    final ed25519 = Ed25519();
    if (stored != null) {
      return ed25519.newKeyPairFromSeed(
        base64Url.decode(base64Url.normalize(stored)),
      );
    }
    final pair = await ed25519.newKeyPair();
    await _secureStorage.write(
      key: _signingSeedKey,
      value: base64UrlEncode(
        await pair.extractPrivateKeyBytes(),
      ).replaceAll('=', ''),
    );
    return pair;
  }

  /// 生成 32 字节随机 nonce 的 base64url 编码（无 padding）。
  String _randomRefreshNonce() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

/// 将网络错误包装为统一失败结果。
NetworkFailure<void> _failure({
  required NetworkErrorCode code,
  required String message,
}) => NetworkFailure<void>(
  NetworkError(
    code: code,
    message: message,
    operation: NetworkOperation.enrollRelay,
  ),
);

/// 将 Relay 源站转换为稳定的安全存储绑定字符串。
String _credentialEndpoint(Uri endpoint) =>
    endpoint.replace(path: '', query: null, fragment: null).toString();

/// 校验端点是没有隐式权限的 HTTPS 源站。
Uri _validatedEndpoint(Uri endpoint) {
  if (endpoint.scheme != 'https' ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.query.isNotEmpty ||
      endpoint.fragment.isNotEmpty ||
      (endpoint.path.isNotEmpty && endpoint.path != '/')) {
    throw ArgumentError.value(
      endpoint,
      'endpoint',
      'must be an HTTPS Relay origin without credentials, query, or fragment',
    );
  }
  return endpoint.replace(path: '');
}
