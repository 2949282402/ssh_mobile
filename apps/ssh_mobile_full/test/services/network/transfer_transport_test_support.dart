import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

extension TransferNetworkResultErrorCode on NetworkResult<Object?> {
  NetworkErrorCode get errorCode => switch (this) {
    NetworkFailure<Object?> failure => failure.error.code,
    _ => fail('Expected a network failure, got $runtimeType'),
  };
}

final class TransferFakeCommandGateway implements NetworkCommandGateway {
  TransferFakeCommandGateway({this.status = TransportOperationStatus.success});

  final TransportOperationStatus status;
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  final NetworkProtocolV2Codec _codec = const NetworkProtocolV2Codec();
  final List<Uint8List> commands = <Uint8List>[];

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    if (status != TransportOperationStatus.success) return status;
    commands.add(command);
    final commandId = _codec.commandId(command);
    scheduleMicrotask(() {
      if (!_events.isClosed) _events.add(transferCommandResultFrame(commandId));
    });
    return status;
  }

  void emit(Uint8List frame) => _events.add(frame);

  Future<void> close() => _events.close();
}

Uint8List transferCommandResultFrame(String commandId) => Uint8List.fromList(
  transferEventFrame(13, <int>[
    ...transferBytesField(1, utf8.encode(commandId)),
    ...transferVarintField(2, 1),
  ]),
);

Uint8List transferEventFrame(int eventField, List<int> payload) =>
    Uint8List.fromList(<int>[
      ...transferBytesField(1, utf8.encode('event-a')),
      ...transferVarintField(2, 1),
      ...transferVarintField(3, 2),
      ...transferBytesField(eventField, payload),
    ]);

List<int> transferVarintField(int fieldNumber, int value) => <int>[
  ...transferVarint(fieldNumber << 3),
  ...transferVarint(value),
];

List<int> transferBytesField(int fieldNumber, List<int> value) => <int>[
  ...transferVarint((fieldNumber << 3) | 2),
  ...transferVarint(value.length),
  ...value,
];

List<int> transferVarint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    final next = remaining & 0x7f;
    remaining >>= 7;
    bytes.add(remaining == 0 ? next : next | 0x80);
  } while (remaining != 0);
  return bytes;
}

Future<PeerStateChanged> firstPeerEvent(
  NetworkService service,
  bool Function(PeerStateChanged event) predicate,
) => service.events
    .where((event) => event is PeerStateChanged)
    .cast<PeerStateChanged>()
    .firstWhere(predicate);

Future<IncomingTransferOffer> firstOffer(NetworkService service) => service
    .events
    .where((event) => event is IncomingTransferOffer)
    .cast<IncomingTransferOffer>()
    .first;

Future<TransferCompleted> firstCompleted(NetworkService service) => service
    .events
    .where((event) => event is TransferCompleted)
    .cast<TransferCompleted>()
    .first;

Future<TransferFailed> firstFailed(NetworkService service) => service.events
    .where((event) => event is TransferFailed)
    .cast<TransferFailed>()
    .first;

void expectNetworkSuccess<T>(NetworkResult<T> result, String operation) {
  if (result is NetworkFailure<T>) {
    final error = result.error;
    fail(
      '$operation failed: '
      'code=${error.code.name}; '
      'message=${error.message}; '
      'operation=${error.operation?.wireName ?? '<none>'}; '
      'peerId=${error.peerId ?? '<none>'}',
    );
  }
  expect(
    result,
    isA<NetworkSuccess<T>>(),
    reason: '$operation returned ${result.runtimeType}',
  );
}
