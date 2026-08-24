part of 'network_service.dart';

/// Relay 命令适配器：负责 Relay 数据面命令及其连接终态。
final class _NetworkRelayAdapter {
  _NetworkRelayAdapter({
    required this.codec,
    required this.commands,
    required this.eventHub,
  });

  final NetworkProtocolV2Codec codec;
  final _NetworkCommandCoordinator commands;
  final _NetworkEventHub eventHub;

  Future<NetworkResult<void>> configure(RelayConfig config) async {
    commands.ensureUsable();
    final terminalState = Completer<RelayStateChanged>();
    final subscription = eventHub.stream
        .where(
          (event) =>
              event is RelayStateChanged &&
              (event.state == RelayConnectionState.connected ||
                  event.state == RelayConnectionState.failed),
        )
        .cast<RelayStateChanged>()
        .listen((event) {
          if (!terminalState.isCompleted) terminalState.complete(event);
        });
    final result = await commands.submit(
      codec.configureRelayCommand(commandId: const Uuid().v4(), config: config),
      operation: NetworkOperation.configureRelay,
      timeout: const Duration(seconds: 15),
    );
    if (result is NetworkFailure<void>) {
      await subscription.cancel();
      return result;
    }
    try {
      final event = await terminalState.future.timeout(
        const Duration(seconds: 15),
      );
      if (event.state == RelayConnectionState.connected) {
        return const NetworkSuccess<void>(null);
      }
      return _networkFailure(
        event.error ??
            const NetworkError(
              code: NetworkErrorCode.relayError,
              message: 'Relay connection failed',
              operation: NetworkOperation.configureRelay,
            ),
      );
    } on TimeoutException {
      return _networkFailure(
        const NetworkError(
          code: NetworkErrorCode.timeout,
          message: 'Relay connection state timed out',
          operation: NetworkOperation.configureRelay,
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<NetworkResult<void>> disconnect() => commands.submit(
    codec.disconnectRelayCommand(commandId: const Uuid().v4()),
    operation: NetworkOperation.disconnectRelay,
  );
}
