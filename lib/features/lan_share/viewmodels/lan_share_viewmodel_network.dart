// 从 LanShareViewModel 拆出的 v1 原生网络事件处理。
// 确保功能编排文件低于 1000 行维护限制。

part of 'lan_share_viewmodel.dart';

/// [LanShareViewModel] 的网络事件持久化扩展。
extension LanShareViewModelNetworkEvents on LanShareViewModel {
  /// 将类型化原生传输事件应用到持久化 LAN 历史记录。
  void _handleNetworkEvent(NetworkEvent event) {
    switch (event) {
      case TransferProgressEvent(
        :final transferId,
        :final bytesTransferred,
        :final totalBytes,
      ):
        unawaited(
          _enqueueMessagePersistence(
            transferId,
            () => historyDao.updateRecordStatus(
              transferId,
              LanTransferStatus.transferring.toJson(),
              bytesTransferred: bytesTransferred,
              bytesTotal: totalBytes > 0 ? totalBytes : null,
            ),
          ),
        );
      case TransferCompletedEvent(:final transferId, :final localPath):
        unawaited(
          _enqueueMessagePersistence(
            transferId,
            () => historyDao.updateRecordStatus(
              transferId,
              LanTransferStatus.completed.toJson(),
              localPath: localPath.isEmpty ? null : localPath,
            ),
          ),
        );
      case TransferFailedEvent(:final transferId, :final error):
        unawaited(
          _enqueueMessagePersistence(
            transferId,
            () => historyDao.updateRecordStatus(
              transferId,
              LanTransferStatus.failed.toJson(),
              failureReason: error.code.name,
            ),
          ),
        );
      default:
        break;
    }
  }
}
