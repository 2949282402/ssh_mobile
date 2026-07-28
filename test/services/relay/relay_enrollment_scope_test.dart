import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/relay/relay_client.dart';
import 'package:ssh_mobile/services/relay/relay_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('relay credential is scoped to endpoint and device identity', () async {
    late Uri requestedEndpoint;
    final endpoint = Uri.parse('https://relay.example.test:8443');
    final client = RelayClient(
      currentDeviceId: 'device-a',
      securityService: LanSecurityService(),
      enrollmentRequester: (requestEndpoint, payload) async {
        requestedEndpoint = requestEndpoint;
        expect(payload['device_id'], 'device-a');
        expect(payload['protocol_version'], 1);
        return {
          'credential': 'signed-credential',
          'expires_at':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'protocol_version': 1,
        };
      },
    );
    addTearDown(client.dispose);
    await client.enroll(RelaySettings(endpoint: endpoint), '0123456789abcdef');

    expect(requestedEndpoint.path, '/v1/devices/enroll');
    expect(await client.isEnrolled(RelaySettings(endpoint: endpoint)), isTrue);
    expect(
      await client.isEnrolled(
        RelaySettings(endpoint: Uri.parse('https://other.example.test')),
      ),
      isFalse,
    );
  });

  test(
    'relay enrollment rejects HTTP and mismatched server protocol',
    () async {
      final client = RelayClient(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(),
        enrollmentRequester: (_, _) async => {
          'credential': 'signed-credential',
          'expires_at':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'protocol_version': 2,
        },
      );
      addTearDown(client.dispose);

      await expectLater(
        client.enroll(
          RelaySettings(endpoint: Uri.parse('http://relay.example.test')),
          '0123456789abcdef',
        ),
        throwsArgumentError,
      );
      await expectLater(
        client.enroll(
          RelaySettings(endpoint: Uri.parse('https://relay.example.test')),
          '0123456789abcdef',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'Dart connect headers and ready handshake match the Go server',
    () async {
      late Map<String, dynamic> enrollmentPayload;
      late Uri socketEndpoint;
      late Map<String, String> socketHeaders;
      final socket = _FakeRelaySocket();
      final client = RelayClient(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(),
        enrollmentRequester: (_, payload) async {
          enrollmentPayload = payload;
          return {
            'credential': 'signed-credential',
            'expires_at':
                DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000,
            'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'protocol_version': 1,
          };
        },
        socketConnector: (endpoint, headers) async {
          socketEndpoint = endpoint;
          socketHeaders = headers;
          socket.addFromServer(
            jsonEncode({
              'type': 'ready',
              'device_id': 'device-a',
              'protocol_version': 1,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }),
          );
          return socket;
        },
      );
      addTearDown(client.dispose);
      final settings = RelaySettings(
        endpoint: Uri.parse('https://relay.example.test:8443'),
      );

      await client.enroll(settings, '0123456789abcdef');
      await client.connect(settings);

      expect(
        socketEndpoint.toString(),
        'wss://relay.example.test:8443/v1/connect',
      );
      expect(socketHeaders['authorization'], 'Bearer signed-credential');
      final nonce = socketHeaders['X-Relay-Nonce']!;
      final signatureBytes = base64Url.decode(
        base64Url.normalize(socketHeaders['X-Relay-Signature']!),
      );
      final publicKeyBytes = base64Url.decode(
        base64Url.normalize(enrollmentPayload['public_key'] as String),
      );
      final verified = await Ed25519().verify(
        utf8.encode('GET\n/v1/connect\n$nonce'),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
      expect(verified, isTrue);
      expect(client.isConnected, isTrue);
    },
  );
}

class _FakeRelaySocket implements RelaySocket {
  final StreamController<dynamic> _messages = StreamController<dynamic>();
  bool closed = false;

  @override
  Stream<dynamic> get messages => _messages.stream;

  void addFromServer(dynamic value) => _messages.add(value);

  @override
  void add(dynamic data) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) return;
    closed = true;
    await _messages.close();
  }
}
