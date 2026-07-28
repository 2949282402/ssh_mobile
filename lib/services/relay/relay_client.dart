import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lan_share/lan_security_service.dart';
import 'relay_chunk_cipher.dart';
import 'relay_models.dart';

typedef RelayEnrollmentRequester =
    Future<Map<String, dynamic>> Function(
      Uri endpoint,
      Map<String, dynamic> payload,
    );
typedef RelaySocketConnector =
    Future<RelaySocket> Function(Uri endpoint, Map<String, String> headers);

class RelayNativeConfiguration {
  const RelayNativeConfiguration({
    required this.endpoint,
    required this.credential,
    required this.signingSeed,
  });

  final Uri endpoint;
  final String credential;
  final Uint8List signingSeed;
}

abstract interface class RelaySocket {
  Stream<dynamic> get messages;

  void add(dynamic data);

  Future<void> close([int? code, String? reason]);
}

class _IoRelaySocket implements RelaySocket {
  _IoRelaySocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  void add(dynamic data) => _socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);
}

/// Client for the memory-only Go relay. It routes encrypted envelopes only;
/// filesystem writes and SFTP reads remain outside this class.
class RelayClient {
  RelayClient({
    required this.currentDeviceId,
    required this.securityService,
    FlutterSecureStorage? secureStorage,
    RelayEnrollmentRequester? enrollmentRequester,
    RelaySocketConnector? socketConnector,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _enrollmentRequester = enrollmentRequester ?? _postEnrollment,
       _socketConnector = socketConnector ?? _connectSocket;

  static const _credentialKey = 'relay_device_credential_v1';
  static const _signingSeedKey = 'relay_device_signing_seed_v1';
  static const protocolVersion = 1;
  static const enrollPath = '/v1/devices/enroll';
  static const connectPath = '/v1/connect';
  static const _maxControlFrameBytes = 64 * 1024;
  static const _heartbeatInterval = Duration(seconds: 20);
  static const _heartbeatTimeout = Duration(seconds: 60);
  final String currentDeviceId;
  final LanSecurityService securityService;
  final FlutterSecureStorage _secureStorage;
  final RelayEnrollmentRequester _enrollmentRequester;
  final RelaySocketConnector _socketConnector;
  final _controls = StreamController<RelayControlFrame>.broadcast();
  final _binaryFrames = StreamController<RelayBinaryFrame>.broadcast();
  RelaySocket? _socket;
  Completer<void>? _readyCompleter;
  Timer? _heartbeatTimer;
  DateTime? _lastHeartbeatAck;
  int _connectionEpoch = 0;
  bool _connected = false;

  Stream<RelayControlFrame> get controls => _controls.stream;
  Stream<RelayBinaryFrame> get binaryFrames => _binaryFrames.stream;
  bool get isConnected => _connected;

  Future<void> enroll(RelaySettings settings, String enrollmentToken) async {
    final endpoint = _validatedEndpoint(settings.endpoint);
    if (currentDeviceId.isEmpty || currentDeviceId.length > 128) {
      throw StateError('Relay device ID must contain 1-128 characters.');
    }
    if (enrollmentToken.length < 16) {
      throw ArgumentError.value(
        enrollmentToken,
        'enrollmentToken',
        'must contain at least 16 characters',
      );
    }
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
      throw StateError('Relay omitted credential.');
    }
    if (responseVersion != protocolVersion) {
      throw StateError('Relay returned an unsupported protocol version.');
    }
    if (serverExpiresAt == null ||
        serverTime == null ||
        serverExpiresAt <= serverTime) {
      throw StateError('Relay returned an expired credential.');
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
  }

  Future<void> connect(RelaySettings settings) async {
    final connectionEpoch = ++_connectionEpoch;
    await _closeCurrentSocket();
    final endpoint = _validatedEndpoint(settings.endpoint);
    final credential = await _credentialFor(RelaySettings(endpoint: endpoint));
    if (credential == null || credential.isEmpty) {
      throw StateError('Relay enrollment is required.');
    }
    final nonceBytes = _randomBytes(32);
    final nonce = base64UrlEncode(nonceBytes).replaceAll('=', '');
    final signature = await Ed25519().sign(
      utf8.encode('GET\n$connectPath\n$nonce'),
      keyPair: await _signingKeyPair(),
    );
    final socketUri = _webSocketUri(endpoint, connectPath);
    final socket = await _socketConnector(socketUri, {
      HttpHeaders.authorizationHeader: 'Bearer $credential',
      'X-Relay-Nonce': nonce,
      'X-Relay-Signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
    }).timeout(const Duration(seconds: 12));
    if (connectionEpoch != _connectionEpoch) {
      await socket.close();
      throw StateError('Relay connection was superseded.');
    }
    final ready = Completer<void>();
    _readyCompleter = ready;
    _socket = socket;
    socket.messages.listen(
      (value) => _handleMessage(socket, ready, value),
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(StateError('Relay closed before ready.'));
        }
        if (identical(_socket, socket)) {
          _stopHeartbeat();
          _connected = false;
          _socket = null;
        }
      },
      onError: (Object error) {
        if (!ready.isCompleted) {
          ready.completeError(error);
        }
        if (identical(_socket, socket)) {
          _stopHeartbeat();
          _connected = false;
          _socket = null;
        }
      },
      cancelOnError: true,
    );
    try {
      await ready.future.timeout(const Duration(seconds: 5));
      if (!identical(_socket, socket)) {
        throw StateError('Relay disconnected during handshake.');
      }
      _connected = true;
      _lastHeartbeatAck = DateTime.now();
      _heartbeatTimer = Timer.periodic(
        _heartbeatInterval,
        (_) => _sendHeartbeat(socket),
      );
    } catch (_) {
      if (identical(_socket, socket)) {
        _stopHeartbeat();
        _connected = false;
        _socket = null;
        await socket.close();
      }
      rethrow;
    } finally {
      if (identical(_readyCompleter, ready)) {
        _readyCompleter = null;
      }
    }
  }

  Future<bool> isEnrolled(RelaySettings settings) async =>
      (await _credentialFor(settings)) != null;

  /// Exports current-protocol Relay identity material for the in-process Rust
  /// runtime. The returned secret is never persisted outside secure storage.
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

  Future<void> disconnect() async {
    _connectionEpoch++;
    await _closeCurrentSocket();
  }

  Future<void> _closeCurrentSocket() async {
    _stopHeartbeat();
    _connected = false;
    final socket = _socket;
    _socket = null;
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('Relay connection was cancelled.'));
    }
    _readyCompleter = null;
    if (socket != null) {
      await socket.close();
    }
  }

  Future<void> sendControl(RelayControlFrame frame) async {
    final socket = _requireSocket();
    final encoded = encodeRelayControlFrame(frame);
    if (utf8.encode(encoded).length > _maxControlFrameBytes) {
      throw ArgumentError('Relay control frame is too large.');
    }
    socket.add(encoded);
  }

  void sendBinary(RelayBinaryFrame frame) {
    if (frame.payload.length > RelayChunkCipher.maxPlaintextChunkBytes + 16) {
      throw ArgumentError('Relay ciphertext chunk is too large.');
    }
    _requireSocket().add(encodeRelayBinaryFrame(frame));
  }

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

  RelaySocket _requireSocket() =>
      (_connected ? _socket : null) ??
      (throw StateError('Relay is not connected.'));

  void _handleMessage(
    RelaySocket source,
    Completer<void> ready,
    dynamic value,
  ) {
    if (!identical(_socket, source)) return;
    try {
      if (value is String) {
        if (utf8.encode(value).length > _maxControlFrameBytes) {
          throw const FormatException('Relay control frame is too large.');
        }
        final decoded = jsonDecode(value);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Relay control frame must be an object.');
        }
        final type = decoded['type'];
        if (type == 'ready') {
          if (decoded['protocol_version'] != protocolVersion ||
              decoded['device_id'] != currentDeviceId) {
            throw const FormatException('Invalid Relay ready frame.');
          }
          if (!ready.isCompleted) ready.complete();
          return;
        }
        if (type == 'heartbeat_ack') {
          _lastHeartbeatAck = DateTime.now();
          return;
        }
        if (type == 'lookup_response') return;
        final frame = decodeRelayControlFrame(decoded);
        if (frame == null) {
          throw const FormatException('Invalid Relay transfer frame.');
        }
        _controls.add(frame);
        return;
      }
      if (value is List<int>) {
        final frame = decodeRelayBinaryFrame(Uint8List.fromList(value));
        if (frame == null) {
          throw const FormatException('Invalid Relay binary frame.');
        }
        _binaryFrames.add(frame);
      }
    } on Object {
      _stopHeartbeat();
      _connected = false;
      if (identical(_socket, source)) _socket = null;
      unawaited(
        source.close(WebSocketStatus.protocolError, 'invalid relay frame'),
      );
    }
  }

  void _sendHeartbeat(RelaySocket socket) {
    if (!_connected || !identical(_socket, socket)) return;
    final lastAck = _lastHeartbeatAck;
    if (lastAck == null ||
        DateTime.now().difference(lastAck) > _heartbeatTimeout) {
      unawaited(disconnect());
      return;
    }
    socket.add(
      jsonEncode({
        'type': 'heartbeat',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastHeartbeatAck = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _controls.close();
    await _binaryFrames.close();
  }
}

Uri _webSocketUri(Uri endpoint, String path) => endpoint.replace(
  scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
  path: path,
  query: null,
);
Uint8List _randomBytes(int length) => Uint8List.fromList(
  List<int>.generate(length, (_) => Random.secure().nextInt(256)),
);

String _credentialEndpoint(Uri endpoint) =>
    endpoint.replace(path: '', query: null, fragment: null).toString();

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

String encodeRelayControlFrame(RelayControlFrame frame) {
  if (!_isRelaySessionId(frame.sessionId)) {
    throw ArgumentError.value(
      frame.sessionId,
      'sessionId',
      'must be 16 bytes encoded as 32 hexadecimal characters',
    );
  }
  if (frame.type == RelayControlType.offer &&
      (frame.targetId == null ||
          frame.targetId!.isEmpty ||
          frame.targetId!.length > 128)) {
    throw ArgumentError('Relay offers require a target device ID.');
  }
  return jsonEncode({
    'type': frame.type.wireName,
    'session_id': frame.sessionId,
    if (frame.targetId != null) 'target_id': frame.targetId,
    if (frame.payload != null)
      'payload': base64UrlEncode(frame.payload!).replaceAll('=', ''),
  });
}

RelayControlFrame? decodeRelayControlFrame(Map<String, dynamic> decoded) {
  final typeValue = decoded['type'];
  final sessionId = decoded['session_id'];
  final senderId = decoded['sender_id'];
  if (typeValue is! String ||
      sessionId is! String ||
      senderId is! String ||
      senderId.isEmpty ||
      senderId.length > 128 ||
      !_isRelaySessionId(sessionId)) {
    return null;
  }
  final type = RelayControlType.fromWireName(typeValue);
  if (type == null) return null;
  final payloadValue = decoded['payload'];
  Uint8List? payload;
  if (payloadValue != null) {
    if (payloadValue is! String) return null;
    try {
      payload = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(payloadValue)),
      );
    } on FormatException {
      return null;
    }
  }
  return RelayControlFrame(
    type: type,
    sessionId: sessionId,
    peerId: senderId,
    payload: payload,
  );
}

Uint8List encodeRelayBinaryFrame(RelayBinaryFrame frame) {
  if (frame.sequence < 0) {
    throw ArgumentError.value(
      frame.sequence,
      'sequence',
      'must be nonnegative',
    );
  }
  final header = ByteData(25)..setUint64(17, frame.sequence, Endian.big);
  final data = header.buffer.asUint8List();
  data[0] = frame.kind;
  data.setRange(1, 17, relaySessionIdBytes(frame.sessionId));
  return Uint8List.fromList(data + frame.payload);
}

RelayBinaryFrame? decodeRelayBinaryFrame(Uint8List bytes) {
  if (bytes.length < 25 ||
      bytes.length > 1024 * 1024 + 25 ||
      bytes[0] != 0x10) {
    return null;
  }
  final sessionId = bytes
      .sublist(1, 17)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return RelayBinaryFrame(
    kind: bytes[0],
    sessionId: sessionId,
    sequence: ByteData.sublistView(bytes, 17, 25).getUint64(0, Endian.big),
    payload: bytes.sublist(25),
  );
}

bool _isRelaySessionId(String value) =>
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

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
      throw StateError('Relay enrollment failed (${response.statusCode}).');
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

Future<RelaySocket> _connectSocket(
  Uri endpoint,
  Map<String, String> headers,
) async {
  final socket = await WebSocket.connect(endpoint.toString(), headers: headers);
  return _IoRelaySocket(socket);
}
