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

/// Client for the memory-only Go relay. It routes encrypted envelopes only;
/// filesystem writes and SFTP reads remain outside this class.
class RelayClient {
  RelayClient({
    required this.currentDeviceId,
    required this.securityService,
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           );

  static const _credentialKey = 'relay_device_credential_v1';
  static const _signingSeedKey = 'relay_device_signing_seed_v1';
  final String currentDeviceId;
  final LanSecurityService securityService;
  final FlutterSecureStorage _secureStorage;
  final _controls = StreamController<RelayControlFrame>.broadcast();
  final _binaryFrames = StreamController<RelayBinaryFrame>.broadcast();
  WebSocket? _socket;

  Stream<RelayControlFrame> get controls => _controls.stream;
  Stream<RelayBinaryFrame> get binaryFrames => _binaryFrames.stream;
  bool get isConnected => _socket != null;

  Future<void> enroll(RelaySettings settings, String enrollmentToken) async {
    final pair = await _signingKeyPair();
    final publicKey = await pair.extractPublicKey();
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        settings.endpoint.resolve('/v1/devices/register'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'device_id': currentDeviceId,
          'public_key': base64UrlEncode(publicKey.bytes).replaceAll('=', ''),
          'enrollment_token': enrollmentToken,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Relay enrollment failed (${response.statusCode}).');
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final credential = decoded['credential'] as String?;
      if (credential == null || credential.isEmpty) {
        throw StateError('Relay omitted credential.');
      }
      await _secureStorage.write(key: _credentialKey, value: credential);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> connect(RelaySettings settings) async {
    await disconnect();
    final credential = await _secureStorage.read(key: _credentialKey);
    if (credential == null || credential.isEmpty) {
      throw StateError('Relay enrollment is required.');
    }
    final nonceBytes = _randomBytes(32);
    final nonce = base64UrlEncode(nonceBytes).replaceAll('=', '');
    final signature = await Ed25519().sign(
      nonceBytes,
      keyPair: await _signingKeyPair(),
    );
    final socketUri = _webSocketUri(settings.endpoint, '/v1/connect');
    final socket = await WebSocket.connect(
      socketUri.toString(),
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $credential',
        'X-Relay-Nonce': nonce,
        'X-Relay-Signature': base64UrlEncode(
          signature.bytes,
        ).replaceAll('=', ''),
      },
    ).timeout(const Duration(seconds: 12));
    _socket = socket;
    socket.listen(
      _handleMessage,
      onDone: () {
        if (identical(_socket, socket)) _socket = null;
      },
      onError: (_) {
        if (identical(_socket, socket)) _socket = null;
      },
      cancelOnError: true,
    );
  }

  Future<void> disconnect() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close();
    }
  }

  Future<void> sendControl(RelayControlFrame frame) async {
    final socket = _requireSocket();
    socket.add(
      jsonEncode({
        'type': frame.type.name,
        'session_id': frame.sessionId,
        if (frame.targetId != null) 'target_id': frame.targetId,
        if (frame.payload != null)
          'payload': base64UrlEncode(frame.payload!).replaceAll('=', ''),
      }),
    );
  }

  void sendBinary(RelayBinaryFrame frame) {
    if (frame.payload.length > RelayChunkCipher.maxPlaintextChunkBytes + 16) {
      throw ArgumentError('Relay ciphertext chunk is too large.');
    }
    final header = ByteData(25)..setUint64(17, frame.sequence, Endian.big);
    final data = header.buffer.asUint8List();
    data[0] = frame.kind;
    data.setRange(1, 17, relaySessionIdBytes(frame.sessionId));
    _requireSocket().add(Uint8List.fromList(data + frame.payload));
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

  WebSocket _requireSocket() =>
      _socket ?? (throw StateError('Relay is not connected.'));
  void _handleMessage(dynamic value) {
    if (value is String) {
      final decoded = jsonDecode(value) as Map<String, dynamic>;
      final type = RelayControlType.values.byName(decoded['type'] as String);
      final payload = decoded['payload'] as String?;
      _controls.add(
        RelayControlFrame(
          type: type,
          sessionId: decoded['session_id'] as String,
          targetId: decoded['target_id'] as String?,
          payload: payload == null
              ? null
              : Uint8List.fromList(
                  base64Url.decode(base64Url.normalize(payload)),
                ),
        ),
      );
      return;
    }
    if (value is List<int> && value.length >= 25) {
      final bytes = Uint8List.fromList(value);
      final sessionId = bytes
          .sublist(1, 17)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      _binaryFrames.add(
        RelayBinaryFrame(
          kind: bytes[0],
          sessionId: sessionId,
          sequence: ByteData.sublistView(
            bytes,
            17,
            25,
          ).getUint64(0, Endian.big),
          payload: bytes.sublist(25),
        ),
      );
    }
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
