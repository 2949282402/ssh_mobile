// Network Protocol V2 transfer, route, relay, and command-result event tests.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

import 'network_protocol_v2_codec_test_utils.dart';

void main() {
  const codec = NetworkProtocolV2Codec();

  test(
    'remaining V2 event families preserve optional fields and unknown data',
    () {
      final error = <int>[
        ...varintField(1, NetworkErrorCode.peerOffline.wireValue),
        ...bytesField(2, utf8.encode('peer is offline')),
        ...bytesField(3, utf8.encode(NetworkOperation.connect.wireName)),
        ...bytesField(4, utf8.encode('peer-a')),
        ...varintField(5, RetryDisposition.retryAfter.wireValue),
        ...varintField(6, 9),
        ...unknownFields(),
      ];

      final peerState = codec.decodeEvent(
        Uint8List.fromList(
          codecFrame(10, <int>[
            ...bytesField(1, utf8.encode('peer-a')),
            ...varintField(2, PeerConnectionState.failed.wireValue),
            ...varintField(3, NetworkRouteType.relay.wireValue),
            ...bytesField(4, error),
            ...varintField(5, NetworkRouteTopology.relay.wireValue),
            ...varintField(6, NetworkRouteTransport.webSocket.wireValue),
            ...unknownFields(),
          ]),
        ),
      );
      expect(peerState.event, isA<PeerStateChanged>());
      final peerEvent = peerState.event! as PeerStateChanged;
      expect(peerEvent.error?.retryAfterSeconds, 9);
      expect(peerEvent.routeType, NetworkRouteType.relay);

      final progress =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      codecFrame(11, <int>[
                        ...bytesField(1, utf8.encode('transfer-a')),
                        ...varintField(2, 10),
                        ...varintField(3, 100),
                        ...unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as TransferProgress;
      expect(progress.bytesTransferred, 10);
      expect(progress.totalBytes, 100);

      final offer =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      codecFrame(14, <int>[
                        ...bytesField(1, utf8.encode('transfer-a')),
                        ...bytesField(2, utf8.encode('peer-a')),
                        ...bytesField(3, utf8.encode('payload.bin')),
                        ...varintField(4, 4096),
                        ...varintField(5, NetworkRouteType.relay.wireValue),
                        ...unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as IncomingTransferOffer;
      expect(offer.fileName, 'payload.bin');
      expect(offer.fileSize, 4096);
      expect(offer.routeType, NetworkRouteType.relay);

      final completed =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      codecFrame(15, <int>[
                        ...bytesField(1, utf8.encode('transfer-a')),
                        ...bytesField(2, utf8.encode('/receive/payload.bin')),
                        ...unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as TransferCompleted;
      expect(completed.localPath, '/receive/payload.bin');

      final failed =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      codecFrame(16, <int>[
                        ...bytesField(1, utf8.encode('transfer-a')),
                        ...bytesField(2, error),
                        ...unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as TransferFailed;
      expect(failed.error.code, NetworkErrorCode.peerOffline);
      expect(failed.error.operation, NetworkOperation.connect);

      final route =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      codecFrame(17, <int>[
                        ...bytesField(1, utf8.encode('peer-a')),
                        ...varintField(
                          2,
                          NetworkRouteType.quicDirect.wireValue,
                        ),
                        ...bytesField(3, utf8.encode('203.0.113.8:4433')),
                        ...varintField(4, 26),
                        ...varintField(5, 7),
                        ...varintField(
                          6,
                          NetworkRouteTopology.direct.wireValue,
                        ),
                        ...varintField(7, NetworkRouteTransport.quic.wireValue),
                        ...unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as RouteChanged;
      expect(route.snapshot.endpoint, '203.0.113.8:4433');
      expect(route.snapshot.rtt, const Duration(milliseconds: 26));
      expect(route.snapshot.loss, 0.007);
      expect(route.snapshot.transport, NetworkRouteTransport.quic);

      final attempt =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      codecFrame(33, <int>[
                        ...bytesField(1, utf8.encode('peer-a')),
                        ...bytesField(2, utf8.encode('attempt-a')),
                        ...varintField(
                          3,
                          RouteAttemptPhase.relayFallbackStarted.wireValue,
                        ),
                        ...varintField(4, NetworkRouteType.relay.wireValue),
                        ...bytesField(5, error),
                        ...unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as RouteAttemptChanged;
      expect(attempt.peerId, 'peer-a');
      expect(attempt.attemptId, 'attempt-a');
      expect(attempt.phase, RouteAttemptPhase.relayFallbackStarted);
      expect(attempt.routeType, NetworkRouteType.relay);
      expect(attempt.error?.code, NetworkErrorCode.peerOffline);

      final relay =
          codec
                  .decodeEvent(
                    Uint8List.fromList(
                      codecFrame(18, <int>[
                        ...varintField(
                          1,
                          RelayConnectionState.failed.wireValue,
                        ),
                        ...bytesField(2, error),
                        ...unknownFields(),
                      ]),
                    ),
                  )
                  .event!
              as RelayStateChanged;
      expect(relay.state, RelayConnectionState.failed);
      expect(relay.error?.peerId, 'peer-a');

      final legacyResult = codec.decodeEvent(
        Uint8List.fromList(
          codecFrame(13, <int>[
            ...bytesField(1, utf8.encode('command-a')),
            ...varintField(2, 0),
            ...bytesField(3, error),
            ...unknownFields(),
          ]),
        ),
      );
      expect(legacyResult.commandId, 'command-a');
      expect(legacyResult.commandAccepted, isFalse);
      expect(legacyResult.commandError?.code, NetworkErrorCode.peerOffline);
    },
  );
}
