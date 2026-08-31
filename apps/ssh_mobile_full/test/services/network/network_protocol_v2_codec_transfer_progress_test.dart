// Network Protocol V2 peer-scoped transfer event tests.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

import 'network_protocol_v2_codec_test_utils.dart';

void main() {
  const codec = NetworkProtocolV2Codec();

  group('Network V2 transfer event peer ownership codec contract', () {
    test(
      'tag 32 (PeerTransferProgressEvent) decodes peerId and progress to TransferProgress',
      () {
        final frame = codec.decodeEvent(
          Uint8List.fromList(
            codecFrame(32, <int>[
              ...bytesField(1, utf8.encode('peer-a')),
              ...bytesField(2, utf8.encode('tx-1')),
              ...varintField(3, 4096),
              ...varintField(4, 8192),
              ...varintField(5, 0), // paused = false
              ...unknownFields(),
            ]),
          ),
        );

        expect(frame.event, isA<TransferProgress>());
        final progress = frame.event! as TransferProgress;
        expect(progress.peerId, 'peer-a');
        expect(progress.transferId, 'tx-1');
        expect(progress.bytesTransferred, 4096);
        expect(progress.totalBytes, 8192);
      },
    );

    test(
      'tag 11 (TransferProgressEvent) preserves peerId in TransferProgress',
      () {
        final frame = codec.decodeEvent(
          Uint8List.fromList(
            codecFrame(11, <int>[
              ...bytesField(1, utf8.encode('tx-2')),
              ...varintField(2, 1024),
              ...varintField(3, 2048),
              ...bytesField(4, utf8.encode('peer-b')),
              ...unknownFields(),
            ]),
          ),
        );

        expect(frame.event, isA<TransferProgress>());
        final progress = frame.event! as TransferProgress;
        expect(progress.peerId, 'peer-b');
        expect(progress.transferId, 'tx-2');
        expect(progress.bytesTransferred, 1024);
        expect(progress.totalBytes, 2048);
      },
    );

    test(
      'tag 15 (TransferCompletedEvent) preserves peerId in TransferCompleted',
      () {
        final frame = codec.decodeEvent(
          Uint8List.fromList(
            codecFrame(15, <int>[
              ...bytesField(1, utf8.encode('tx-3')),
              ...bytesField(2, utf8.encode('/tmp/received_file.bin')),
              ...bytesField(3, utf8.encode('peer-c')),
              ...unknownFields(),
            ]),
          ),
        );

        expect(frame.event, isA<TransferCompleted>());
        final completed = frame.event! as TransferCompleted;
        expect(completed.peerId, 'peer-c');
        expect(completed.transferId, 'tx-3');
        expect(completed.localPath, '/tmp/received_file.bin');
      },
    );

    test('tag 16 (TransferFailedEvent) preserves peerId in TransferFailed', () {
      final error = <int>[
        ...varintField(1, NetworkErrorCode.ioError.wireValue),
        ...bytesField(2, utf8.encode('io error')),
        ...bytesField(3, utf8.encode(NetworkOperation.send.wireName)),
        ...bytesField(4, utf8.encode('peer-d')),
      ];

      final frame = codec.decodeEvent(
        Uint8List.fromList(
          codecFrame(16, <int>[
            ...bytesField(1, utf8.encode('tx-4')),
            ...bytesField(2, error),
            ...bytesField(3, utf8.encode('peer-d')),
            ...unknownFields(),
          ]),
        ),
      );

      expect(frame.event, isA<TransferFailed>());
      final failed = frame.event! as TransferFailed;
      expect(failed.peerId, 'peer-d');
      expect(failed.transferId, 'tx-4');
      expect(failed.error.code, NetworkErrorCode.ioError);
    });
  });
}
