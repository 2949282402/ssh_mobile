import 'dart:async';

import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// App Shell adapter from the Runtime-owned native Realtime gateway to the
/// high-level network_sdk session contract.
///
/// Native owns PeerConnection, SDP, ICE, signaling, sockets, and media
/// resources. This adapter only maps typed lifecycle events and queue-level
/// command status; it never forwards native signaling to a Feature.
final class AppRealtimeSessionBackend implements RealtimeSessionBackend {
  AppRealtimeSessionBackend({required this._networkRuntime});

  final NetworkRuntime _networkRuntime;
  final StreamController<RealtimeBackendEvent> _events =
      StreamController<RealtimeBackendEvent>.broadcast();
  NetworkRealtimeGateway? _gateway;
  Future<NetworkRealtimeGateway>? _gatewayFuture;
  StreamSubscription<NativeNetworkEvent>? _nativeSubscription;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  Stream<RealtimeBackendEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> start({
    required String realtimeId,
    required String peerId,
  }) async {
    _ensureUsable();
    final gateway = await _ensureGateway();
    return _mapStatus(
      gateway.start(realtimeId: realtimeId, peerId: peerId),
      operation: NetworkOperation.connect,
      peerId: peerId,
    );
  }

  @override
  Future<SdkResult<void>> stop({required String realtimeId}) async {
    _ensureUsable();
    final gateway = await _ensureGateway();
    return _mapStatus(
      gateway.stop(realtimeId: realtimeId),
      operation: NetworkOperation.disconnect,
    );
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    if (_disposed) return Future<void>.value();
    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<NetworkRealtimeGateway> _ensureGateway() {
    final current = _gateway;
    if (current != null) return Future<NetworkRealtimeGateway>.value(current);
    final existing = _gatewayFuture;
    if (existing != null) return existing;

    late final Future<NetworkRealtimeGateway> future;
    future = _networkRuntime.openRealtimeGateway();
    _gatewayFuture = future;
    future.then<void>(
      (gateway) {
        if (!identical(_gatewayFuture, future) || _disposed) return;
        _gatewayFuture = null;
        _gateway = gateway;
        _nativeSubscription = gateway.events.listen(_onNativeEvent);
      },
      onError: (Object _, StackTrace _) {
        if (identical(_gatewayFuture, future)) _gatewayFuture = null;
      },
    );
    return future;
  }

  void _onNativeEvent(NativeNetworkEvent event) {
    if (_disposed) return;
    switch (event) {
      case NativeRealtimeStateChangedEvent(
        :final realtimeId,
        :final peerId,
        :final state,
        :final error,
      ):
        _events.add(
          RealtimeSessionStateChangedEvent(
            realtimeId: realtimeId,
            peerId: peerId,
            state: _mapState(state),
            error: error == null ? null : _mapError(error),
          ),
        );
      case NativeCommandResultEvent():
      case NativeRealtimeSignalEvent():
      // Command acceptance and SDP/ICE signaling are native concerns. The
      // session state event is the only lifecycle source for Features.
    }
  }

  Future<void> _disposeResources() async {
    final pendingGateway = _gatewayFuture;
    if (pendingGateway != null) {
      try {
        await pendingGateway;
      } catch (_) {
        // A failed lazy open has no subscription to cancel.
      }
    }
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    _gateway = null;
    _gatewayFuture = null;
    await _events.close();
  }

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }

  static SdkResult<void> _mapStatus(
    NativeOperationStatus status, {
    required NetworkOperation operation,
    String? peerId,
  }) => switch (status) {
    NativeOperationStatus.success => const SdkSuccess<void>(null),
    NativeOperationStatus.invalidArgument => SdkFailure<void>(
      NetworkError(
        code: NetworkErrorCode.invalidArgument,
        message: 'Realtime command arguments were rejected.',
        operation: operation,
        peerId: peerId,
      ),
    ),
    NativeOperationStatus.stopped => SdkFailure<void>(
      NetworkError(
        code: NetworkErrorCode.cancelled,
        message: 'Native network runtime is stopped.',
        operation: operation,
        peerId: peerId,
      ),
    ),
    NativeOperationStatus.failure => SdkFailure<void>(
      NetworkError(
        code: NetworkErrorCode.ioError,
        message: 'Native Realtime command was not queued.',
        operation: operation,
        peerId: peerId,
      ),
    ),
  };

  static RealtimeSessionState _mapState(
    NativeRealtimeSessionState state,
  ) => switch (state) {
    NativeRealtimeSessionState.unspecified => RealtimeSessionState.idle,
    NativeRealtimeSessionState.negotiating => RealtimeSessionState.negotiating,
    NativeRealtimeSessionState.connected => RealtimeSessionState.connected,
    NativeRealtimeSessionState.restarting => RealtimeSessionState.restarting,
    NativeRealtimeSessionState.closed => RealtimeSessionState.stopped,
    NativeRealtimeSessionState.failed => RealtimeSessionState.failed,
  };

  static NetworkError _mapError(NativeNetworkError error) => NetworkError(
    code: NetworkErrorCode.fromWire(error.code),
    message: error.message,
    peerId: error.peerId,
  );
}
