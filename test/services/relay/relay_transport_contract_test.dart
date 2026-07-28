import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_share_models.dart';
import 'package:ssh_mobile/services/relay/relay_client.dart';
import 'package:ssh_mobile/services/relay/relay_models.dart';
import 'package:ssh_mobile/services/relay/relay_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  final target = LanDevice(
    id: 'device-b',
    alias: 'Device B',
    ip: '203.0.113.2',
    port: 443,
    deviceType: LanDeviceType.desktop,
    osName: 'Windows',
    lastSeen: DateTime.utc(2026),
  );

  test('sender reports success only after receiver completion ack', () async {
    final peerKey = await X25519().newKeyPair();
    final peerPublicKey = await peerKey.extractPublicKey();
    final client = _FakeRelayClient(acknowledgeCompletion: true);
    final transport = RelayTransport(
      client: client,
      securityService: LanSecurityService(),
      responseTimeout: const Duration(seconds: 1),
    );
    addTearDown(client.dispose);

    final success = await transport.sendFile(
      target: target,
      fileName: 'report.txt',
      totalBytes: 3,
      stream: Stream.value([1, 2, 3]),
      peerPublicKey: Uint8List.fromList(peerPublicKey.bytes),
    );

    expect(
      success,
      isTrue,
      reason:
          'sent=${client.sentControls.map((frame) => frame.type.wireName).toList()}',
    );
    expect(
      client.sentControls.map((frame) => frame.type),
      containsAllInOrder([
        RelayControlType.offer,
        RelayControlType.complete,
        RelayControlType.cancel,
      ]),
    );
  });

  test(
    'sender does not claim success without receiver completion ack',
    () async {
      final peerKey = await X25519().newKeyPair();
      final peerPublicKey = await peerKey.extractPublicKey();
      final client = _FakeRelayClient(acknowledgeCompletion: false);
      final transport = RelayTransport(
        client: client,
        securityService: LanSecurityService(),
        responseTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(client.dispose);

      final success = await transport.sendFile(
        target: target,
        fileName: 'report.txt',
        totalBytes: 3,
        stream: Stream.value([1, 2, 3]),
        peerPublicKey: Uint8List.fromList(peerPublicKey.bytes),
      );

      expect(success, isFalse);
    },
  );

  test(
    'receiver binds an offer to server sender and acknowledges completion',
    () async {
      final security = LanSecurityService();
      final recipientPublicKey = await security.getStaticX25519PublicKeyBytes();
      const sessionId = '00112233445566778899aabbccddeeff';
      final encryptedOffer = await security.encryptE2EFor(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'v': 1,
              'session_id': sessionId,
              'sender_id': 'device-a',
              'receiver_id': 'device-b',
              'file_name': 'empty.txt',
              'file_size': 0,
              'content_key': base64UrlEncode(Uint8List(32)).replaceAll('=', ''),
              'nonce_prefix': base64UrlEncode(Uint8List(4)).replaceAll('=', ''),
            }),
          ),
        ),
        recipientPublicKey,
      );
      final client = _FakeRelayClient(
        acknowledgeCompletion: false,
        deviceId: 'device-b',
      );
      final transport = RelayTransport(
        client: client,
        securityService: security,
      );
      addTearDown(client.dispose);

      final offer = await transport.decodeIncomingOffer(
        RelayControlFrame(
          type: RelayControlType.offer,
          sessionId: sessionId,
          peerId: 'device-a',
          payload: encryptedOffer,
        ),
      );
      expect(offer?.senderId, 'device-a');
      expect(offer?.fileName, 'empty.txt');
      expect(offer?.isComplete, isTrue);

      await transport.acknowledgeComplete(offer!);
      expect(client.sentControls.last.type, RelayControlType.completeAck);
    },
  );
}

class _FakeRelayClient extends RelayClient {
  _FakeRelayClient({
    required this.acknowledgeCompletion,
    this.deviceId = 'device-a',
  }) : super(currentDeviceId: deviceId, securityService: LanSecurityService());

  final bool acknowledgeCompletion;
  final String deviceId;
  final StreamController<RelayControlFrame> _fakeControls =
      StreamController<RelayControlFrame>.broadcast();
  final List<RelayControlFrame> sentControls = [];

  @override
  bool get isConnected => true;

  @override
  Stream<RelayControlFrame> get controls => _fakeControls.stream;

  @override
  Future<void> sendControl(RelayControlFrame frame) async {
    sentControls.add(frame);
    if (frame.type == RelayControlType.offer) {
      _fakeControls.add(
        RelayControlFrame(
          type: RelayControlType.accept,
          sessionId: frame.sessionId,
          peerId: 'device-b',
        ),
      );
    } else if (frame.type == RelayControlType.complete &&
        acknowledgeCompletion) {
      _fakeControls.add(
        RelayControlFrame(
          type: RelayControlType.completeAck,
          sessionId: frame.sessionId,
          peerId: 'device-b',
        ),
      );
    }
  }

  @override
  void sendBinary(RelayBinaryFrame frame) {}

  @override
  Future<void> dispose() async {
    await _fakeControls.close();
    await super.dispose();
  }
}
