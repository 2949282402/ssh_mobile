part of 'network_service.dart';

/// 将 native runtime 适配为共享 gateway；gateway 不拥有 runtime。
final class _NativeRuntimeCommandGateway implements NetworkCommandGateway {
  _NativeRuntimeCommandGateway(this._runtime);

  final NativeNetworkRuntime _runtime;

  @override
  Stream<Uint8List> get events => _runtime.rawEvents;

  @override
  TransportOperationStatus sendCommand(Uint8List command) =>
      switch (_runtime.sendCommand(command)) {
        NativeOperationStatus.success => TransportOperationStatus.success,
        NativeOperationStatus.invalidArgument =>
          TransportOperationStatus.invalidArgument,
        NativeOperationStatus.stopped => TransportOperationStatus.stopped,
        NativeOperationStatus.failure => TransportOperationStatus.failure,
      };
}
