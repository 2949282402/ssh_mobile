import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/lan_share/lan_pairing_crypto.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';

Map<String, dynamic> _credential({
  String status = 'pending_remote',
  String nonce = 'request-nonce',
  String handshakeId = 'handshake-id',
  String requestHash = 'request-hash',
  String issuerDeviceId = 'peer-device',
  String recipientDeviceId = 'local-device',
  int validForMs = LanPairingCrypto.credentialTtlMillis,
}) {
  return {
    'protocolVersion': LanPairingCrypto.protocolVersion,
    'accessToken': 'pair-access-token',
    'status': status,
    'certFingerprint': List<String>.filled(64, 'a').join(),
    'requestNonce': nonce,
    'handshakeId': handshakeId,
    'requestHash': requestHash,
    'issuerDeviceId': issuerDeviceId,
    'recipientDeviceId': recipientDeviceId,
    'validForMs': validForMs,
  };
}

void main() {
  late LanTransferService service;
  setUp(() {
    service = LanTransferService(
      currentDeviceId: 'local-device',
      securityService: LanSecurityService(),
      storageService: LanStorageService(),
    );
  });

  tearDown(() {
    service.dispose();
  });

  bool isValid(
    Map<String, dynamic> credential, {
    Duration elapsed = Duration.zero,
  }) {
    return service.isPairingCredentialBindingValidForTesting(
      credential,
      expectedNonce: 'fresh-request-nonce',
      expectedHandshakeId: 'fresh-handshake-id',
      expectedRequestHash: 'fresh-request-hash',
      expectedIssuerDeviceId: 'peer-device',
      expectedRecipientDeviceId: 'local-device',
      elapsed: elapsed,
    );
  }

  test('an old response cannot be replayed for a fresh request nonce', () {
    final replayed = _credential(
      nonce: 'old-request-nonce',
      handshakeId: 'fresh-handshake-id',
      requestHash: 'fresh-request-hash',
    );

    expect(isValid(replayed), isFalse);

    final legacyUnbound = Map<String, dynamic>.from(replayed)
      ..remove('requestNonce');
    expect(isValid(legacyUnbound), isFalse);
  });

  test('wrong bindings and invalid relative lifetime are rejected', () {
    expect(
      isValid(
        _credential(
          nonce: 'fresh-request-nonce',
          handshakeId: 'fresh-handshake-id',
          requestHash: 'fresh-request-hash',
          issuerDeviceId: 'other-peer',
        ),
      ),
      isFalse,
    );
    expect(
      isValid(
        _credential(
          nonce: 'fresh-request-nonce',
          handshakeId: 'fresh-handshake-id',
          requestHash: 'fresh-request-hash',
          recipientDeviceId: 'other-recipient',
        ),
      ),
      isFalse,
    );
    expect(
      isValid(
        _credential(
          nonce: 'fresh-request-nonce',
          handshakeId: 'wrong-handshake-id',
          requestHash: 'fresh-request-hash',
        ),
      ),
      isFalse,
    );
    expect(
      isValid(
        _credential(
          nonce: 'fresh-request-nonce',
          handshakeId: 'fresh-handshake-id',
          requestHash: 'wrong-request-hash',
        ),
      ),
      isFalse,
    );
    expect(
      isValid(
        _credential(
          nonce: 'fresh-request-nonce',
          handshakeId: 'fresh-handshake-id',
          requestHash: 'fresh-request-hash',
          validForMs: 0,
        ),
      ),
      isFalse,
    );
    expect(
      isValid(
        _credential(
          nonce: 'fresh-request-nonce',
          handshakeId: 'fresh-handshake-id',
          requestHash: 'fresh-request-hash',
        ),
        elapsed: const Duration(
          milliseconds: LanPairingCrypto.credentialTtlMillis + 1,
        ),
      ),
      isFalse,
    );
  });

  test('fresh pending and paired credentials remain valid', () {
    for (final status in ['pending_remote', 'paired']) {
      expect(
        isValid(
          _credential(
            nonce: 'fresh-request-nonce',
            handshakeId: 'fresh-handshake-id',
            requestHash: 'fresh-request-hash',
            status: status,
          ),
        ),
        isTrue,
      );
    }
  });
}
