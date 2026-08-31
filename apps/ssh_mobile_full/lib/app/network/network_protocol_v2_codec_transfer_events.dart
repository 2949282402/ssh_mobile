part of '../../services/network/network_protocol_v2_codec.dart';

/// 独占文件传输事件的类型化映射。
final class _TransferEventDecoder {
  const _TransferEventDecoder();

  /// 解码通用传输进度事件（wire tag 11：TransferProgressEvent）。
  TransferProgress decodeProgress(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var transferred = 0;
    var total = 0;
    var peerId = '';
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          transferred = reader.varint(field.wireType);
        case 3:
          total = reader.varint(field.wireType);
        case 4:
          peerId = utf8.decode(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return TransferProgress(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      bytesTransferred: transferred,
      totalBytes: total,
      peerId: peerId.isEmpty ? null : peerId,
    );
  }

  /// 解码对端作用域传输进度事件（wire tag 32：PeerTransferProgressEvent）。
  TransferProgress decodePeerTransferProgress(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    var transferId = '';
    var confirmedOffset = 0;
    var totalBytes = 0;
    var paused = false;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 3:
          confirmedOffset = reader.varint(field.wireType);
        case 4:
          totalBytes = reader.varint(field.wireType);
        case 5:
          paused = reader.varint(field.wireType) != 0;
        default:
          reader.skip(field.wireType);
      }
    }
    final _ = paused;
    return TransferProgress(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      bytesTransferred: confirmedOffset,
      totalBytes: totalBytes,
      peerId: peerId.isEmpty ? null : peerId,
    );
  }

  IncomingTransferOffer decodeOffer(
    String eventId,
    int timestampMs,
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
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          peerId = utf8.decode(reader.bytes(field.wireType));
        case 3:
          fileName = utf8.decode(reader.bytes(field.wireType));
        case 4:
          fileSize = reader.varint(field.wireType);
        case 5:
          route = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return IncomingTransferOffer(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      peerId: peerId,
      fileName: fileName,
      fileSize: fileSize,
      routeType: NetworkRouteType.fromWire(route),
    );
  }

  TransferCompleted decodeCompleted(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    var localPath = '';
    var peerId = '';
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          localPath = utf8.decode(reader.bytes(field.wireType));
        case 3:
          peerId = utf8.decode(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return TransferCompleted(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      localPath: localPath,
      peerId: peerId.isEmpty ? null : peerId,
    );
  }

  TransferFailed decodeFailed(
    String eventId,
    int timestampMs,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var transferId = '';
    NetworkError? error;
    var peerId = '';
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          transferId = utf8.decode(reader.bytes(field.wireType));
        case 2:
          error = _decodeNetworkError(reader.bytes(field.wireType));
        case 3:
          peerId = utf8.decode(reader.bytes(field.wireType));
        default:
          reader.skip(field.wireType);
      }
    }
    return TransferFailed(
      eventId: eventId,
      timestamp: _eventTimestamp(timestampMs),
      transferId: transferId,
      error:
          error ??
          const NetworkError(
            code: NetworkErrorCode.unspecified,
            message: 'transfer failed',
          ),
      peerId: peerId.isEmpty ? null : peerId,
    );
  }
}
