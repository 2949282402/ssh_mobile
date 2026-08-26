// 从 LanShareViewModel 拆出的 Network V2 原生网络事件处理。
// 确保功能编排文件低于 1000 行维护限制。

part of 'lan_share_viewmodel.dart';

/// [LanShareViewModel] 的网络事件持久化扩展。
extension LanShareViewModelNetworkEvents on LanShareViewModel {
  Future<bool> _eventMatchesRecordPeer(
    String transferId,
    String? eventPeerId,
  ) async {
    if (eventPeerId == null) return true;
    final record = await historyDao.getRecord(transferId);
    if (record == null) {
      logger.warning(
        'Ignoring transfer event for $transferId: no history record found',
      );
      return false;
    }
    final expectedPeerId = record.isIncoming
        ? record.senderId
        : record.receiverId;
    if (expectedPeerId != eventPeerId) {
      logger.warning(
        'Ignoring transfer event for $transferId due to peer mismatch (expected $expectedPeerId, got $eventPeerId)',
      );
      return false;
    }
    return true;
  }

  /// 将类型化原生传输事件应用到持久化 LAN 历史记录。
  void _handleNetworkEvent(NetworkEvent event) {
    switch (event) {
      case TransferProgress(
        :final transferId,
        :final bytesTransferred,
        :final totalBytes,
        :final peerId,
      ):
        _trackBackgroundOperation(
          _enqueueMessagePersistence(transferId, () async {
            if (!await _eventMatchesRecordPeer(transferId, peerId)) return;
            await historyDao.updateRecordStatus(
              transferId,
              LanTransferStatus.transferring.toJson(),
              bytesTransferred: bytesTransferred,
              bytesTotal: totalBytes > 0 ? totalBytes : null,
            );
          }),
          'LAN transfer progress persistence failed',
        );
      case TransferCompleted(
        :final transferId,
        :final localPath,
        :final peerId,
      ):
        _trackBackgroundOperation(
          _enqueueMessagePersistence(transferId, () async {
            final record = await historyDao.getRecord(transferId);
            if (record == null) {
              logger.warning(
                'Ignoring TransferCompleted event for $transferId: no history record found',
              );
              return;
            }
            if (peerId != null) {
              final expectedPeerId = record.isIncoming
                  ? record.senderId
                  : record.receiverId;
              if (expectedPeerId != peerId) {
                logger.warning(
                  'Ignoring TransferCompleted event for $transferId due to peer mismatch (expected $expectedPeerId, got $peerId)',
                );
                return;
              }
            }
            if (record.isIncoming && localPath.isNotEmpty) {
              try {
                final adoptedFile = await storageService
                    .adoptIncomingNetworkFile(
                      nativePath: localPath,
                      fileName: record.fileName ?? 'file.bin',
                    );
                await historyDao.updateRecordStatus(
                  transferId,
                  LanTransferStatus.completed.toJson(),
                  localPath: adoptedFile.path,
                );
              } catch (error) {
                await historyDao.updateRecordStatus(
                  transferId,
                  LanTransferStatus.failed.toJson(),
                  failureReason: NetworkErrorCode.ioError.name,
                );
              }
            } else {
              await historyDao.updateRecordStatus(
                transferId,
                LanTransferStatus.completed.toJson(),
                localPath: localPath.isEmpty ? null : localPath,
              );
            }
          }),
          'LAN transfer completion persistence failed',
        );
      case TransferFailed(:final transferId, :final error, :final peerId):
        _trackBackgroundOperation(
          _enqueueMessagePersistence(transferId, () async {
            if (!await _eventMatchesRecordPeer(transferId, peerId)) return;
            await historyDao.updateRecordStatus(
              transferId,
              LanTransferStatus.failed.toJson(),
              failureReason: error.code.name,
            );
          }),
          'LAN transfer failure persistence failed',
        );
      default:
        break;
    }
  }
}
