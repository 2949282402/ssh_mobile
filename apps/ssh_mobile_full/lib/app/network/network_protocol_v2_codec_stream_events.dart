part of '../../services/network/network_protocol_v2_codec.dart';

/// 独占 SSH ReliableStream handle 与事件载荷解码。
final class _SshStreamEventDecoder {
  const _SshStreamEventDecoder();

  SshStreamDataReceivedEvent decodeData(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    var data = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          handle = _decodeHandle(reader.bytes(field.wireType));
        case 3:
          data = Uint8List.fromList(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return SshStreamDataReceivedEvent(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      handle: streamHandle,
      data: data,
    );
  }

  SshStreamClosedEvent decodeClosed(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          handle = _decodeHandle(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return SshStreamClosedEvent(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      peerId: peerId,
      handle: streamHandle,
    );
  }

  NativeStreamHandle _decodeHandle(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var openerDeviceId = '';
    var streamId = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          openerDeviceId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          streamId = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    if (openerDeviceId.isEmpty || streamId < 1 || streamId > 0xffff) {
      throw const FormatException('SSH stream handle is invalid.');
    }
    return NativeStreamHandle(
      openerDeviceId: openerDeviceId,
      streamId: streamId,
    );
  }
}
