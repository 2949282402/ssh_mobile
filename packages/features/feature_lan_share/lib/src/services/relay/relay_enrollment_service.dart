// v1 Relay enrollment 与原生凭据桥接；Dart 不承载 Relay 数据面。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/network_models.dart';

/// 允许测试和平台适配层注入 HTTPS enrollment 调用。
typedef RelayEnrollmentRequester =
    Future<Map<String, dynamic>> Function(
      Uri endpoint,
      Map<String, dynamic> payload,
    );

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
    FlutterSecureStorage? secureStorage,
    RelayEnrollmentRequester? enrollmentRequester,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _enrollmentRequester = enrollmentRequester ?? _postEnrollment;

  /// 绑定在 enrollment 凭据中的当前设备标识。
  final String currentDeviceId;
  final FlutterSecureStorage _secureStorage;
  final RelayEnrollmentRequester _enrollmentRequester;

  /// Go 与 Rust Relay 共享的当前开发线协议版本。
  static const int protocolVersion = 1;

  /// v1 enrollment 端点。
  static const String enrollPath = '/v1/devices/enroll';

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
      final decoded = await _enrollmentRequester(endpoint.resolve(enrollPath), {
        'device_id': currentDeviceId,
        'public_key': base64UrlEncode(publicKey.bytes).replaceAll('=', ''),
        'enrollment_token': enrollmentToken,
        'protocol_version': protocolVersion,
        'platform': Platform.operatingSystem,
      });
      final credential = decoded['credential'] as String?;
      final responseVersion = (decoded['protocol_version'] as num?)?.toInt();
      final serverExpiresAt = (decoded['expires_at'] as num?)?.toInt();
      final serverTime = (decoded['server_time'] as num?)?.toInt();
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (credential == null || credential.isEmpty) {
        return _failure(
          code: NetworkErrorCode.relayError,
          message: 'Relay enrollment response omitted credentials.',
        );
      }
      if (responseVersion != protocolVersion) {
        return _failure(
          code: NetworkErrorCode.relayError,
          message: 'Relay enrollment response used an unsupported protocol.',
        );
      }
      if (serverExpiresAt == null ||
          serverTime == null ||
          serverExpiresAt <= serverTime) {
        return _failure(
          code: NetworkErrorCode.relayError,
          message: 'Relay enrollment response contained an invalid expiry.',
        );
      }
      final localExpiresAt = nowSeconds + (serverExpiresAt - serverTime);
      await _secureStorage.write(
        key: _credentialKey,
        value: jsonEncode({
          'endpoint': _credentialEndpoint(endpoint),
          'device_id': currentDeviceId,
          'credential': credential,
          'expires_at': localExpiresAt,
          'protocol_version': responseVersion,
        }),
      );
      return const NetworkSuccess<void>(null);
    } on Object catch (error) {
      return NetworkFailure<void>(_networkError(error));
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
}

/// 将 enrollment 异常映射为公开网络错误，不暴露底层异常文本。
NetworkError _networkError(Object error) {
  if (error is TimeoutException) {
    return const NetworkError(
      code: NetworkErrorCode.timeout,
      message: 'Relay enrollment timed out.',
      operation: NetworkOperation.enrollRelay,
    );
  }
  if (error is ArgumentError) {
    return const NetworkError(
      code: NetworkErrorCode.invalidArgument,
      message: 'Relay enrollment arguments are invalid.',
      operation: NetworkOperation.enrollRelay,
    );
  }
  if (error is _RelayEnrollmentHttpException &&
      error.statusCode == HttpStatus.unauthorized) {
    return const NetworkError(
      code: NetworkErrorCode.authenticationFailed,
      message: 'Relay enrollment authentication failed.',
      operation: NetworkOperation.enrollRelay,
    );
  }
  return const NetworkError(
    code: NetworkErrorCode.relayError,
    message: 'Relay enrollment failed.',
    operation: NetworkOperation.enrollRelay,
  );
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

/// 记录 enrollment HTTP 状态，供错误策略转换为稳定错误码。
final class _RelayEnrollmentHttpException implements Exception {
  /// 创建带 HTTP 状态码的内部 enrollment 异常。
  const _RelayEnrollmentHttpException(this.statusCode);

  /// 导致失败的 HTTP 状态码。
  final int statusCode;
}

/// 执行生产 HTTPS enrollment 请求，并限制响应体大小。
Future<Map<String, dynamic>> _postEnrollment(
  Uri endpoint,
  Map<String, dynamic> payload,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await _readBoundedUtf8(response, 64 * 1024);
    if (response.statusCode != HttpStatus.ok) {
      throw _RelayEnrollmentHttpException(response.statusCode);
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Relay enrollment response must be JSON.');
    }
    return decoded;
  } finally {
    client.close(force: true);
  }
}

/// 在固定内存上限内读取 enrollment 响应。
Future<String> _readBoundedUtf8(Stream<List<int>> source, int maxBytes) async {
  final bytes = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in source) {
    total += chunk.length;
    if (total > maxBytes) {
      throw const FormatException('Relay response is too large.');
    }
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes());
}

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
