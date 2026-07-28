import 'dart:async';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import '../lan_share/lan_transfer_service.dart';

enum TransportKind { legacyHttps, quicDirect, relayFallback }

class TransferSession {
  final String transferId;
  final String peerId;
  final String filePath;
  final TransportKind transport;

  TransferSession({
    required this.transferId,
    required this.peerId,
    required this.filePath,
    required this.transport,
  });
}

class TransferEvent {
  final String transferId;
  final int bytesTransferred;
  final int totalBytes;
  final String? error;

  TransferEvent({
    required this.transferId,
    required this.bytesTransferred,
    required this.totalBytes,
    this.error,
  });
}

/// Abstract transport interface for file transfer across LAN HTTPS, QUIC P2P, and Relay.
abstract interface class TransferTransport {
  Future<TransferSession> send({
    required String peerId,
    required String filePath,
  });

  Future<void> cancel(String transferId);

  Stream<TransferEvent> get events;
}

/// Legacy HTTPS transport implementation wrapping existing LanTransferService.
class LegacyLanTransferTransport implements TransferTransport {
  final LanTransferService _lanTransferService;
  final StreamController<TransferEvent> _eventController =
      StreamController<TransferEvent>.broadcast();

  LegacyLanTransferTransport(this._lanTransferService);

  LanTransferService get lanTransferService => _lanTransferService;

  @override
  Future<TransferSession> send({
    required String peerId,
    required String filePath,
  }) async {
    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    return TransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      transport: TransportKind.legacyHttps,
    );
  }

  @override
  Future<void> cancel(String transferId) async {}

  @override
  Stream<TransferEvent> get events => _eventController.stream;
}

/// QUIC P2P transport implementation wrapping SshMobileNetworkNative SDK.
class QuicTransferTransport implements TransferTransport {
  final SshMobileNetworkNative _native;
  final StreamController<TransferEvent> _eventController =
      StreamController<TransferEvent>.broadcast();

  QuicTransferTransport(this._native);

  SshMobileNetworkNative get native => _native;

  @override
  Future<TransferSession> send({
    required String peerId,
    required String filePath,
  }) async {
    final transferId = DateTime.now().millisecondsSinceEpoch.toString();
    return TransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      transport: TransportKind.quicDirect,
    );
  }

  @override
  Future<void> cancel(String transferId) async {}

  @override
  Stream<TransferEvent> get events => _eventController.stream;
}
