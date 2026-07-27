import 'dart:typed_data';

enum RelayControlType { offer, accept, resume, cancel }

class RelaySettings {
  const RelaySettings({required this.endpoint});

  final Uri endpoint;
}

/// A client-only checkpoint. It deliberately contains no file bytes or relay
/// credential, so it is safe to place behind the encrypted storage facade.
class RelayTransferCheckpoint {
  const RelayTransferCheckpoint({
    required this.transferId,
    required this.connectionId,
    required this.remotePath,
    required this.sourceSize,
    required this.sourceModifiedMillis,
    required this.confirmedOffset,
  });

  final String transferId;
  final String connectionId;
  final String remotePath;
  final int sourceSize;
  final int sourceModifiedMillis;
  final int confirmedOffset;
}

class RelayControlFrame {
  const RelayControlFrame({
    required this.type,
    required this.sessionId,
    this.targetId,
    this.payload,
  });

  final RelayControlType type;
  final String sessionId;
  final String? targetId;
  final Uint8List? payload;
}

class RelayBinaryFrame {
  const RelayBinaryFrame({
    required this.kind,
    required this.sessionId,
    required this.sequence,
    required this.payload,
  });

  final int kind;
  final String sessionId;
  final int sequence;
  final Uint8List payload;
}
