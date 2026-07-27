import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/relay/relay_chunk_cipher.dart';

void main() {
  const sessionId = '00112233445566778899aabbccddeeff';
  final cipher = RelayChunkCipher(
    key: Uint8List.fromList(List<int>.generate(32, (i) => i)),
    baseNonce: Uint8List.fromList([1, 2, 3, 4]),
  );

  test(
    'round trips a bounded chunk only with its session and sequence',
    () async {
      final encrypted = await cipher.encrypt(
        sessionId: sessionId,
        sequence: 2,
        plaintext: Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await cipher.decrypt(
          sessionId: sessionId,
          sequence: 2,
          ciphertext: encrypted,
        ),
        [1, 2, 3],
      );
      await expectLater(
        cipher.decrypt(
          sessionId: sessionId,
          sequence: 3,
          ciphertext: encrypted,
        ),
        throwsA(anything),
      );
    },
  );
}
