part of 'network_service.dart';

/// Transfer 命令适配器：负责本地文件边界、传输生命周期和会话构造。
final class _NetworkTransferAdapter {
  _NetworkTransferAdapter({
    required this.codec,
    required this.commands,
    required this.projection,
  });

  final NetworkProtocolV2Codec codec;
  final _NetworkCommandCoordinator commands;
  final _NetworkStateProjection projection;

  Future<NetworkResult<TransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async {
    commands.ensureUsable();
    if (transferId.trim().isEmpty || peerId.trim().isEmpty) {
      return _networkFailure(
        const NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'transfer_id and peer_id are required',
          operation: NetworkOperation.send,
        ),
      );
    }
    final file = File(filePath);
    if (!await file.exists()) {
      return _networkFailure(
        const NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'source file is unavailable',
          operation: NetworkOperation.send,
        ),
      );
    }
    final absolutePath = file.absolute.path;
    projection.trackTransfer(transferId, peerId);
    final result = await commands.submit(
      codec.sendFileCommand(
        commandId: const Uuid().v4(),
        transferId: transferId,
        peerId: peerId,
        filePath: absolutePath,
      ),
      operation: NetworkOperation.send,
    );
    if (result is NetworkFailure<void>) {
      projection.untrackTransfer(transferId);
      return _networkFailure(result.error);
    }
    return NetworkSuccess<TransferSession>(
      TransferSession(
        transferId: transferId,
        peerId: peerId,
        filePath: absolutePath,
        routeType: projection.routeTypeFor(peerId),
      ),
    );
  }

  Future<NetworkResult<void>> cancel(String transferId) {
    commands.ensureUsable();
    if (transferId.trim().isEmpty) {
      return Future.value(
        _networkFailure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'transfer_id is required',
            operation: NetworkOperation.cancel,
          ),
        ),
      );
    }
    return commands.submit(
      codec.cancelTransferCommand(
        commandId: const Uuid().v4(),
        transferId: transferId,
      ),
      operation: NetworkOperation.cancel,
    );
  }

  Future<NetworkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) {
    commands.ensureUsable();
    return commands.submit(
      codec.respondIncomingTransferCommand(
        commandId: const Uuid().v4(),
        transferId: transferId,
        accept: accept,
      ),
      operation: NetworkOperation.respondToIncoming,
    );
  }
}
