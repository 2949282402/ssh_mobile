part of 'network_service.dart';

/// Peer 命令适配器：只负责 peer registration 与连接状态终态等待。
final class _NetworkPeerAdapter {
  _NetworkPeerAdapter({
    required this.codec,
    required this.commands,
    required this.eventHub,
    required this.projection,
  });

  final NetworkProtocolV2Codec codec;
  final _NetworkCommandCoordinator commands;
  final _NetworkEventHub eventHub;
  final _NetworkStateProjection projection;

  Future<NetworkResult<void>> upsertPeer(PeerConfig peer) => commands.submit(
    codec.upsertPeerCommand(commandId: const Uuid().v4(), peer: peer),
    operation: NetworkOperation.upsertPeer,
  );

  Future<NetworkResult<void>> removePeer(String peerId) {
    commands.ensureUsable();
    if (peerId.trim().isEmpty) {
      return Future.value(
        _networkFailure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'peer_id is required',
            operation: NetworkOperation.removePeer,
          ),
        ),
      );
    }
    return commands.submit(
      codec.removePeerCommand(commandId: const Uuid().v4(), peerId: peerId),
      operation: NetworkOperation.removePeer,
    );
  }

  Future<NetworkResult<void>> connect(
    String peerId, {
    required CommunicationClass communicationClass,
  }) async {
    commands.ensureUsable();
    if (peerId.trim().isEmpty) {
      return _networkFailure(
        const NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'peer_id is required',
          operation: NetworkOperation.connect,
        ),
      );
    }
    if (projection.hasRoute(peerId)) {
      return const NetworkSuccess<void>(null);
    }

    final terminalState = Completer<PeerStateChanged>();
    final subscription = eventHub.stream
        .where(
          (event) =>
              event is PeerStateChanged &&
              event.peerId == peerId &&
              (event.state == PeerConnectionState.connected ||
                  event.state == PeerConnectionState.failed ||
                  event.state == PeerConnectionState.disconnected),
        )
        .cast<PeerStateChanged>()
        .listen((event) {
          if (!terminalState.isCompleted) terminalState.complete(event);
        });
    final result = await commands.submit(
      codec.connectPeerCommand(
        commandId: const Uuid().v4(),
        peerId: peerId,
        communicationClass: communicationClass,
      ),
      operation: NetworkOperation.connect,
      timeout: const Duration(seconds: 12),
    );
    if (result is NetworkFailure<void>) {
      await subscription.cancel();
      return result;
    }
    try {
      final event = await terminalState.future.timeout(
        const Duration(seconds: 12),
      );
      if (event.state == PeerConnectionState.connected) {
        return const NetworkSuccess<void>(null);
      }
      return _networkFailure(
        event.error ??
            NetworkError(
              code: NetworkErrorCode.noRoute,
              message: 'peer connection failed',
              operation: NetworkOperation.connect,
              peerId: peerId,
            ),
      );
    } on TimeoutException {
      return _networkFailure(
        NetworkError(
          code: NetworkErrorCode.timeout,
          message: 'peer connection state timed out',
          operation: NetworkOperation.connect,
          peerId: peerId,
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<NetworkResult<void>> disconnect(String peerId) {
    commands.ensureUsable();
    if (peerId.trim().isEmpty) {
      return Future.value(
        _networkFailure(
          const NetworkError(
            code: NetworkErrorCode.invalidArgument,
            message: 'peer_id is required',
            operation: NetworkOperation.disconnect,
          ),
        ),
      );
    }
    return commands.submit(
      codec.disconnectPeerCommand(commandId: const Uuid().v4(), peerId: peerId),
      operation: NetworkOperation.disconnect,
    );
  }
}
