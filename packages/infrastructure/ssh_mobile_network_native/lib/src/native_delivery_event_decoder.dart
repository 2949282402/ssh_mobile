part of 'native_realtime_protocol.dart';

/// Owns command-result, Delivery, and Transfer event mapping.
final class _NativeDeliveryEventDecoder {
  static const _values = _NativeProtocolValueMapper();

  static NativeCommandResultEvent _decodeCommandResult(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var commandId = '';
    var accepted = false;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          commandId = reader.string(field.wireType, _maxCommandIdBytes);
        case 2:
          accepted = reader.varint(field.wireType) != 0;
        case 3:
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    if (commandId.isEmpty) {
      throw const FormatException('Native command result has no command ID.');
    }
    return NativeCommandResultEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      commandId: commandId,
      accepted: accepted,
      error: error,
    );
  }

  static NativeCommandResultV2Event _decodeCommandResultV2(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var commandId = '';
    var peerId = '';
    var state = 0;
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          commandId = reader.string(field.wireType, _maxCommandIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    if (commandId.isEmpty) {
      throw const FormatException(
        'Native V2 command result has no command ID.',
      );
    }
    return NativeCommandResultV2Event(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      commandId: commandId,
      peerId: peerId,
      state: state,
      error: error,
    );
  }

  static NativeTransferProgressEvent _decodeTransferProgress(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var bytesTransferred = 0;
    var totalBytes = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          bytesTransferred = reader.varint(field.wireType);
        case 3:
          totalBytes = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
    return NativeTransferProgressEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
    );
  }

  static NativeIncomingTransferOfferEvent _decodeIncomingTransferOffer(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var peerId = '';
    var fileName = '';
    var fileSize = 0;
    var route = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          fileName = reader.string(field.wireType, _maxFileNameBytes);
        case 4:
          fileSize = reader.varint(field.wireType);
        case 5:
          route = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(fileName, 'file name');
    return NativeIncomingTransferOfferEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
      peerId: peerId,
      fileName: fileName,
      fileSize: fileSize,
      routeType: NativeRouteType.fromWire(route),
    );
  }

  static NativeTransferCompletedEvent _decodeTransferCompleted(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var localPath = '';
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          localPath = reader.string(field.wireType, _maxEventBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
    return NativeTransferCompletedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
      localPath: localPath,
    );
  }

  static NativeTransferFailedEvent _decodeTransferFailed(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = reader.string(field.wireType, _maxTransferIdBytes);
        case 2:
          error = _values.decodeError(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedIdentifier(transferId, 'transfer ID');
    return NativeTransferFailedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      transferId: transferId,
      error: error,
    );
  }

  static NativeChannelMessageEvent _decodeChannelMessage(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var sessionId = '';
    var channelId = '';
    var messageId = Uint8List(0);
    var sequence = 0;
    var payload = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          sessionId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          channelId = reader.string(field.wireType, _maxChannelIdBytes);
        case 4:
          messageId = reader.bytes(field.wireType, _maxMessageIdBytes);
        case 5:
          sequence = reader.varint(field.wireType);
        case 7:
          payload = reader.bytes(field.wireType, _maxEventBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(sessionId, 'session ID');
    _values.validateDecodedIdentifier(channelId, 'channel ID');
    if (messageId.isEmpty) {
      throw const FormatException('Channel message has no message ID.');
    }
    return NativeChannelMessageEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      sessionId: sessionId,
      channelId: channelId,
      messageId: messageId,
      sequence: sequence,
      payload: payload,
    );
  }

  static NativeDeliveryAckedEvent _decodeDeliveryAcked(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var sessionId = '';
    var messageId = Uint8List(0);
    var recoveryEpoch = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          sessionId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          messageId = reader.bytes(field.wireType, _maxMessageIdBytes);
        case 4:
          recoveryEpoch = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    _values.validateDecodedIdentifier(sessionId, 'session ID');
    if (messageId.isEmpty) {
      throw const FormatException('Delivery ACK has no message ID.');
    }
    return NativeDeliveryAckedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      sessionId: sessionId,
      messageId: messageId,
      recoveryEpoch: recoveryEpoch,
    );
  }
}
