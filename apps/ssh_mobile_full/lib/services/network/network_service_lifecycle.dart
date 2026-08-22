part of 'network_service.dart';

/// Runtime 生命周期端口：唯一决定何时停止/释放 App-owned native runtime。
final class _NetworkRuntimeLifecycle {
  _NetworkRuntimeLifecycle({
    required this.ownedRuntime,
    required this.codec,
    required this.commands,
    required this.eventRouter,
    required this.eventHub,
    required this.state,
  });

  final NativeNetworkRuntime? ownedRuntime;
  final NetworkProtocolV2Codec codec;
  final _NetworkCommandCoordinator commands;
  final _NetworkEventRouter eventRouter;
  final _NetworkEventHub eventHub;
  final _NetworkServiceState state;

  Future<NetworkResult<void>> start(NetworkRuntimeConfig config) async {
    state.ensureUsable();
    if (state.stopped) return _networkCancelled(NetworkOperation.start);
    if (state.configured) return const NetworkSuccess<void>(null);
    final result = await commands.submit(
      codec.configureRuntimeCommand(
        commandId: const Uuid().v4(),
        config: config,
      ),
      operation: NetworkOperation.start,
      timeout: const Duration(seconds: 15),
    );
    if (result is NetworkSuccess<void>) state.configured = true;
    return result;
  }

  Future<NetworkResult<void>> stop() async {
    state.ensureUsable();
    if (state.stopped) return const NetworkSuccess<void>(null);
    state.stopped = true;
    commands.cancelPending(operation: NetworkOperation.stop);
    final runtime = ownedRuntime;
    final status = runtime == null
        ? NativeOperationStatus.success
        : await runtime.stop();
    if (!status.isSuccess) {
      return _networkFailure(
        _networkNativeStatusError(status, operation: NetworkOperation.stop),
      );
    }
    await eventRouter.close();
    await eventHub.close();
    return const NetworkSuccess<void>(null);
  }

  Future<void> dispose() async {
    if (state.disposed) return;
    state.disposed = true;
    state.stopped = true;
    commands.cancelPending(operation: NetworkOperation.stop);
    await eventRouter.close();
    await ownedRuntime?.dispose();
    await eventHub.close();
  }
}
