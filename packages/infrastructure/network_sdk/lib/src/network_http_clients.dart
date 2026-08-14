import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'network_clients.dart';
import 'network_models.dart';
import 'network_requests.dart';

/// 使用注入式请求执行器访问当前 v1 Bootstrap HTTP API。
///
/// 该类不创建或关闭 HTTP client；请求执行器由 App Shell 拥有。Relay 数据面
/// 仍由 Rust/native runtime 负责，Bootstrap 只处理探测和 enrollment。
final class JsonBootstrapClient implements BootstrapClient {
  JsonBootstrapClient({
    required this.executor,
    this.requestTimeout = const Duration(seconds: 10),
    this.protocolVersion = 1,
  });

  final SdkRequestExecutor executor;
  final Duration requestTimeout;
  final int protocolVersion;

  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async {
    try {
      final response = await _send(
        SdkRequest(method: 'GET', uri: _resolve(endpoint, '/healthz')),
      );
      if (!response.isSuccessful && response.statusCode != 204) {
        return SdkFailure(
          _httpError(response, NetworkOperation.bootstrapProbe),
        );
      }
      final body = _decodeMap(response.body);
      if (body == null) {
        return SdkSuccess(BootstrapMetadata(protocolVersion: protocolVersion));
      }
      final responseVersion = _readInt(body['protocol_version']);
      if (responseVersion != null && responseVersion != protocolVersion) {
        return SdkFailure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'Bootstrap protocol version is unsupported.',
            operation: NetworkOperation.bootstrapProbe,
          ),
        );
      }
      return SdkSuccess(
        BootstrapMetadata(
          protocolVersion: responseVersion ?? protocolVersion,
          capabilities: _readStringList(body['capabilities']),
          serverTime: _readUnixTime(body['server_time']),
        ),
      );
    } on Object catch (error) {
      return SdkFailure(
        _transportError(error, NetworkOperation.bootstrapProbe),
      );
    }
  }

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async {
    if (request.deviceId.isEmpty || request.deviceId.length > 128) {
      return const SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Enrollment device identity is invalid.',
          operation: NetworkOperation.enrollRelay,
        ),
      );
    }
    if (request.protocolVersion != protocolVersion) {
      return const SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Enrollment protocol version is unsupported.',
          operation: NetworkOperation.enrollRelay,
        ),
      );
    }
    if (request.identityPublicKey.length != 32) {
      return const SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Enrollment identity key is invalid.',
          operation: NetworkOperation.enrollRelay,
        ),
      );
    }
    try {
      final payload = <String, dynamic>{
        'device_id': request.deviceId,
        'public_key': _base64Url(request.identityPublicKey),
        'protocol_version': request.protocolVersion,
        if (request.enrollmentToken != null)
          'enrollment_token': request.enrollmentToken,
        if (request.platform != null) 'platform': request.platform,
      };
      final response = await _send(
        SdkRequest(
          method: 'POST',
          uri: _resolve(endpoint, '/v1/devices/enroll'),
          headers: const <String, String>{
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: _encodeJson(payload),
        ),
      );
      if (!response.isSuccessful) {
        return SdkFailure(_httpError(response, NetworkOperation.enrollRelay));
      }
      final body = _decodeMap(response.body);
      if (body == null) {
        return const SdkFailure(
          NetworkError(
            code: NetworkErrorCode.relayError,
            message: 'Enrollment response is invalid.',
            operation: NetworkOperation.enrollRelay,
          ),
        );
      }
      final credential = body['credential'];
      final responseVersion = _readInt(body['protocol_version']);
      final expiresAt = _readUnixTime(body['expires_at']);
      final serverTime = _readUnixTime(body['server_time']);
      if (credential is! String ||
          credential.isEmpty ||
          responseVersion != protocolVersion ||
          expiresAt == null ||
          serverTime == null ||
          !expiresAt.isAfter(serverTime)) {
        return const SdkFailure(
          NetworkError(
            code: NetworkErrorCode.relayError,
            message: 'Enrollment response is invalid.',
            operation: NetworkOperation.enrollRelay,
          ),
        );
      }
      return SdkSuccess(
        DeviceEnrollment(
          deviceId: request.deviceId,
          relayCredential: credential,
          expiresAt: expiresAt,
          serverTime: serverTime,
          protocolVersion: responseVersion!,
        ),
      );
    } on Object catch (error) {
      return SdkFailure(_transportError(error, NetworkOperation.enrollRelay));
    }
  }

  @override
  Future<SdkResult<DeviceEnrollment>> refresh(
    Uri endpoint,
    RefreshRequest request,
  ) async {
    if (request.deviceId.isEmpty || request.deviceId.length > 128) {
      return const SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Refresh device identity is invalid.',
          operation: NetworkOperation.refreshCredential,
        ),
      );
    }
    if (request.identityPublicKey.length != 32) {
      return const SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Refresh identity key is invalid.',
          operation: NetworkOperation.refreshCredential,
        ),
      );
    }
    if (request.nonce.isEmpty || request.signature.isEmpty) {
      return const SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Refresh proof is invalid.',
          operation: NetworkOperation.refreshCredential,
        ),
      );
    }
    try {
      final payload = <String, dynamic>{
        'device_id': request.deviceId,
        'public_key': _base64Url(request.identityPublicKey),
        'nonce': request.nonce,
        'signature': request.signature,
      };
      final response = await _send(
        SdkRequest(
          method: 'POST',
          uri: _resolve(endpoint, '/v1/devices/refresh'),
          headers: const <String, String>{
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: _encodeJson(payload),
        ),
      );
      if (!response.isSuccessful) {
        final error = _httpError(response, NetworkOperation.refreshCredential);
        // 404 表示设备未 enrollment（例如 relay 重启丢失状态），需要重新 enroll。
        // 共享映射将其归为 relayError；这里收敛为 noRoute 作为稳定的 typed
        // 重-enroll 信号，供 Feature 区分，而不解析错误消息字符串。
        if (response.statusCode == 404) {
          return SdkFailure(error.copyWith(code: NetworkErrorCode.noRoute));
        }
        return SdkFailure(error);
      }
      final body = _decodeMap(response.body);
      if (body == null) {
        return const SdkFailure(
          NetworkError(
            code: NetworkErrorCode.relayError,
            message: 'Refresh response is invalid.',
            operation: NetworkOperation.refreshCredential,
          ),
        );
      }
      final credential = body['credential'];
      final responseVersion = _readInt(body['protocol_version']);
      final expiresAt = _readUnixTime(body['expires_at']);
      final serverTime = _readUnixTime(body['server_time']);
      if (credential is! String ||
          credential.isEmpty ||
          responseVersion != protocolVersion ||
          expiresAt == null ||
          serverTime == null ||
          !expiresAt.isAfter(serverTime)) {
        return const SdkFailure(
          NetworkError(
            code: NetworkErrorCode.relayError,
            message: 'Refresh response is invalid.',
            operation: NetworkOperation.refreshCredential,
          ),
        );
      }
      return SdkSuccess(
        DeviceEnrollment(
          deviceId: request.deviceId,
          relayCredential: credential,
          expiresAt: expiresAt,
          serverTime: serverTime,
          protocolVersion: responseVersion!,
        ),
      );
    } on Object catch (error) {
      return SdkFailure(
        _transportError(error, NetworkOperation.refreshCredential),
      );
    }
  }

  Future<SdkResponse> _send(SdkRequest request) =>
      executor.execute(request).timeout(requestTimeout);
}

/// 鉴权控制面请求所需的具体端点集合。
///
/// 端点由 App Shell 根据部署的控制面版本提供，避免 SDK 猜测服务端路由。
final class AuthenticatedApiRoutes {
  AuthenticatedApiRoutes({
    required this.listPeers,
    required this.requestConnection,
  });

  final Uri listPeers;
  final Uri Function(String peerId) requestConnection;
}

/// 使用 Bearer Session 访问控制面 API 的客户端实现。
///
/// 该实现最多在一次 401 后调用 [AuthSessionProvider.refreshAccessToken] 重试
/// 一次；刷新失败时立即失效当前会话，不把 token 写入错误或事件对象。
final class JsonAuthenticatedApiClient implements AuthenticatedApiClient {
  JsonAuthenticatedApiClient({
    required this.executor,
    required this.authSession,
    required this.routes,
    this.requestTimeout = const Duration(seconds: 10),
  });

  final SdkRequestExecutor executor;
  final AuthSessionProvider authSession;
  final AuthenticatedApiRoutes routes;
  final Duration requestTimeout;

  @override
  Future<SdkResult<List<PeerDescriptor>>> listPeers() => _authorized(
    operation: NetworkOperation.listPeers,
    buildRequest: () => SdkRequest(method: 'GET', uri: routes.listPeers),
    parse: _parsePeers,
  );

  @override
  Future<SdkResult<ConnectionTicket>> requestConnection(String peerId) {
    if (peerId.isEmpty) {
      return Future<SdkResult<ConnectionTicket>>.value(
        const SdkFailure(
          NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'Peer identity is invalid.',
            operation: NetworkOperation.requestConnection,
          ),
        ),
      );
    }
    return _authorized(
      operation: NetworkOperation.requestConnection,
      // Route resolution and body encoding run lazily inside the unified
      // exception boundary, so a resolver/encoder error becomes SdkFailure
      // instead of a raw throw to the caller.
      buildRequest: () => SdkRequest(
        method: 'POST',
        uri: routes.requestConnection(peerId),
        headers: const <String, String>{
          'content-type': 'application/json',
          'accept': 'application/json',
        },
        body: _encodeJson(<String, dynamic>{'peer_id': peerId}),
      ),
      parse: (response) => _parseConnectionTicket(response, peerId),
    );
  }

  Future<SdkResult<T>> _authorized<T>({
    required NetworkOperation operation,
    required SdkRequest Function() buildRequest,
    required T Function(SdkResponse response) parse,
  }) async {
    try {
      // Route resolution and body encoding run lazily inside the boundary so a
      // resolver/encoder error becomes SdkFailure rather than a raw throw.
      final request = buildRequest();
      // The token read is inside the boundary too: a Secure Storage / Keychain /
      // Windows Credential Manager provider failure maps to SdkFailure (ioError).
      final initialToken = await authSession.readAccessToken();
      if (initialToken == null || initialToken.trim().isEmpty) {
        return SdkFailure(
          _authError(
            operation,
            'Authenticated network session is unavailable.',
          ),
        );
      }

      var token = initialToken;
      var response = await _send(_withBearer(request, token));
      if (response.statusCode == 401) {
        final refreshed = await _refreshCredential();
        if (refreshed == null) {
          return SdkFailure(
            _authError(operation, 'Authenticated network session expired.'),
          );
        }
        token = refreshed;
        response = await _send(_withBearer(request, token));
      }
      if (response.statusCode == 401) {
        await _invalidateSafely();
        return SdkFailure(
          _authError(operation, 'Authenticated network session expired.'),
        );
      }
      if (!response.isSuccessful) {
        return SdkFailure(_httpError(response, operation));
      }
      try {
        return SdkSuccess(parse(response));
      } on FormatException {
        return SdkFailure(
          NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'Authenticated network response is invalid.',
            operation: operation,
          ),
        );
      }
    } on Object catch (error) {
      return SdkFailure(_transportError(error, operation));
    }
  }

  /// 401 后刷新凭据。Provider 抛异常或返回空时，先安全失效会话再返回 null，
  /// 满足 "最多刷新一次、失败必须失效会话" 的契约；失败绝不把清理阶段的
  /// 异常覆盖到调用方。
  Future<String?> _refreshCredential() async {
    final String? refreshed;
    try {
      refreshed = await authSession.refreshAccessToken();
    } on Object {
      await _invalidateSafely();
      return null;
    }
    if (refreshed == null || refreshed.trim().isEmpty) {
      await _invalidateSafely();
      return null;
    }
    return refreshed;
  }

  /// 清理阶段失败不得掩盖原始网络错误：忽略 invalidate 自身抛出的异常。
  Future<void> _invalidateSafely() async {
    try {
      await authSession.invalidate();
    } on Object {
      // Session cleanup is best-effort; the original failure is authoritative.
    }
  }

  SdkRequest _withBearer(SdkRequest request, String token) => SdkRequest(
    method: request.method,
    uri: request.uri,
    headers: <String, String>{
      ...request.headers,
      'authorization': 'Bearer ${token.trim()}',
    },
    body: request.body,
  );

  Future<SdkResponse> _send(SdkRequest request) =>
      executor.execute(request).timeout(requestTimeout);
}

List<PeerDescriptor> _parsePeers(SdkResponse response) {
  final decoded = _decodeJson(response.body);
  final values = decoded is List
      ? decoded
      : decoded is Map<String, dynamic>
      ? decoded['peers']
      : null;
  if (values is! List) throw const FormatException('peers is not a list');
  return values
      .map((value) {
        if (value is! Map) throw const FormatException('peer is not an object');
        final peerId = value['peer_id'];
        final displayName = value['display_name'] ?? peerId;
        if (peerId is! String || peerId.isEmpty || displayName is! String) {
          throw const FormatException('peer fields are invalid');
        }
        return PeerDescriptor(peerId: peerId, displayName: displayName);
      })
      .toList(growable: false);
}

ConnectionTicket _parseConnectionTicket(SdkResponse response, String peerId) {
  final decoded = _decodeMap(response.body);
  final value = decoded?['ticket'];
  if (value is! String || value.isEmpty) {
    throw const FormatException('connection ticket is invalid');
  }
  final responsePeerId = decoded?['peer_id'];
  if (responsePeerId != null && responsePeerId != peerId) {
    throw const FormatException('connection ticket peer is invalid');
  }
  return ConnectionTicket(peerId: peerId, value: value);
}

NetworkError _httpError(SdkResponse response, NetworkOperation operation) {
  final errorBody = _decodeMap(response.body);
  final deviceCode = _readInt(errorBody?['code']);
  final code = switch (response.statusCode) {
    409 => NetworkErrorCode.identityConflict,
    401 || 403 =>
      deviceCode == NetworkErrorCode.credentialExpired.wireValue
          ? NetworkErrorCode.credentialExpired
          : NetworkErrorCode.authenticationFailed,
    408 || 429 || >= 500 => NetworkErrorCode.timeout,
    _ => NetworkErrorCode.relayError,
  };
  return NetworkError(
    code: code,
    message: errorBody?['message'] is String
        ? errorBody!['message'] as String
        : _safeMessageFor(code),
    operation: operation,
    retryDisposition: _readRetryDisposition(errorBody?['retry_disposition']),
    retryAfterSeconds: _readInt(errorBody?['retry_after_seconds']) ?? 0,
  );
}

NetworkError _transportError(Object error, NetworkOperation operation) {
  final code = switch (error) {
    TimeoutException() => NetworkErrorCode.timeout,
    ArgumentError() => NetworkErrorCode.invalidArgument,
    _ => NetworkErrorCode.ioError,
  };
  return NetworkError(
    code: code,
    message: code == NetworkErrorCode.invalidArgument
        ? 'Network request arguments are invalid.'
        : _safeMessageFor(code),
    operation: operation,
  );
}

NetworkError _authError(NetworkOperation operation, String message) =>
    NetworkError(
      code: NetworkErrorCode.authenticationFailed,
      message: message,
      operation: operation,
    );

String _safeMessageFor(NetworkErrorCode code) => switch (code) {
  NetworkErrorCode.timeout => 'Network request timed out.',
  NetworkErrorCode.authenticationFailed => 'Network authentication failed.',
  NetworkErrorCode.ioError => 'Network request failed.',
  _ => 'Network request was rejected.',
};

Uri _resolve(Uri endpoint, String path) {
  if ((endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.query.isNotEmpty ||
      endpoint.fragment.isNotEmpty) {
    throw ArgumentError.value(endpoint, 'endpoint', 'invalid network endpoint');
  }
  return endpoint.resolve(path);
}

Map<String, dynamic>? _decodeMap(Uint8List body) {
  if (body.isEmpty) return null;
  final decoded = _decodeJson(body);
  return decoded is Map<String, dynamic> ? decoded : null;
}

Object? _decodeJson(Uint8List body) {
  if (body.isEmpty) return null;
  return jsonDecode(utf8.decode(body));
}

Uint8List _encodeJson(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

String _base64Url(Uint8List value) =>
    base64UrlEncode(value).replaceAll('=', '');

int? _readInt(Object? value) => value is num ? value.toInt() : null;

RetryDisposition _readRetryDisposition(Object? value) => value is num
    ? RetryDisposition.fromWire(value.toInt())
    : RetryDisposition.unspecified;

DateTime? _readUnixTime(Object? value) {
  final seconds = _readInt(value);
  if (seconds == null || seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

List<String> _readStringList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .whereType<String>()
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
