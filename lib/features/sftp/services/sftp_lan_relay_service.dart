import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../../../services/sftp_service.dart';

/// Service responsible for zero-disk-footprint streaming relay from SFTP to LAN targets
class SftpLanRelayService {
  final SftpService sftpService;
  final LanTransferService lanTransferService;

  SftpLanRelayService({
    required this.sftpService,
    required this.lanTransferService,
  });

  /// Relay an SFTP remote file directly to a LAN device without saving to local disk
  Future<bool> relayRemoteFile({
    required String connectionId,
    required SftpEntry entry,
    required LanDevice targetDevice,
    Function(int bytesSent)? onProgress,
  }) async {
    if (entry.isDirectory) {
      debugPrint(
        '[SftpLanRelayService] Directory relay not supported in zero-disk mode',
      );
      return false;
    }

    try {
      // 1. Get SftpClient from SftpService session
      final dynamic sftpClient = sftpService.getSftpClientForConnection(
        connectionId,
      );
      if (sftpClient == null) {
        debugPrint(
          '[SftpLanRelayService] SFTP client not connected for $connectionId',
        );
        return false;
      }

      // 2. Open remote SFTP file stream
      final dynamic remoteFile = await sftpClient.open(entry.path);
      final Stream<List<int>> remoteStream = remoteFile.read();

      // 3. Construct LanMessage
      final messageId = 'sftp_relay_${DateTime.now().millisecondsSinceEpoch}';
      final message = LanMessage(
        id: messageId,
        senderId: lanTransferService.currentDeviceId,
        senderAlias: 'SFTP Relay',
        receiverId: targetDevice.id,
        payloadType: LanPayloadType.sftpRelay,
        fileName: entry.name,
        fileSize: entry.size ?? 0,
        status: LanTransferStatus.transferring,
        createdAt: DateTime.now(),
        isIncoming: false,
        sftpServerId: connectionId,
        sftpRemotePath: entry.path,
      );

      // 4. Send metadata to target device first
      final accepted = await lanTransferService.sendMeta(targetDevice, message);
      if (!accepted) {
        debugPrint(
          '[SftpLanRelayService] Target device rejected relay request',
        );
        return false;
      }

      // 5. Pipe SFTP read stream directly to LAN HTTPS POST request stream
      final success = await lanTransferService.sendFileStream(
        device: targetDevice,
        message: message,
        fileStream: remoteStream,
        totalBytes: entry.size ?? 0,
        onProgress: onProgress,
      );

      return success;
    } catch (e) {
      debugPrint('[SftpLanRelayService] Relay error: $e');
      return false;
    }
  }
}
