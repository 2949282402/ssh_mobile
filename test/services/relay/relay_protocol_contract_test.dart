import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/relay/relay_client.dart';
import 'package:ssh_mobile/services/relay/relay_models.dart';

void main() {
  const sessionId = '00112233445566778899aabbccddeeff';

  test('Dart control frame matches the Go Relay wire names', () {
    final encoded =
        jsonDecode(
              encodeRelayControlFrame(
                const RelayControlFrame(
                  type: RelayControlType.completeAck,
                  sessionId: sessionId,
                ),
              ),
            )
            as Map<String, dynamic>;

    expect(encoded, {'type': 'complete_ack', 'session_id': sessionId});
  });

  test('Dart accepts only server-normalized transfer control frames', () {
    final frame = decodeRelayControlFrame({
      'type': 'offer',
      'session_id': sessionId,
      'sender_id': 'device-a',
      'payload': base64UrlEncode([1, 2, 3]).replaceAll('=', ''),
    });

    expect(frame?.type, RelayControlType.offer);
    expect(frame?.peerId, 'device-a');
    expect(frame?.payload, [1, 2, 3]);
    expect(
      decodeRelayControlFrame({
        'type': 'offer',
        'session_id': sessionId,
        'payload': 'AQ',
      }),
      isNull,
      reason: 'The Relay must bind every transfer frame to its sender.',
    );
    expect(
      decodeRelayControlFrame({
        'type': 'unrecognized',
        'session_id': sessionId,
        'sender_id': 'device-a',
      }),
      isNull,
    );
  });

  test('Dart binary header round trips the Go Relay 25-byte prefix', () {
    final encoded = encodeRelayBinaryFrame(
      RelayBinaryFrame(
        kind: 0x10,
        sessionId: sessionId,
        sequence: 42,
        payload: Uint8List.fromList([4, 5, 6]),
      ),
    );

    expect(encoded.length, 28);
    expect(encoded[0], 0x10);
    final decoded = decodeRelayBinaryFrame(encoded);
    expect(decoded?.sessionId, sessionId);
    expect(decoded?.sequence, 42);
    expect(decoded?.payload, [4, 5, 6]);
    encoded[0] = 0x7f;
    expect(decodeRelayBinaryFrame(encoded), isNull);
  });
}
