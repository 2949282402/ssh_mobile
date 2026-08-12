import 'dart:typed_data';

import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

import '../native/network_command_gateway.dart';
import '../transport/transport_connection.dart';

/// Non-owning typed gateway for a Runtime-owned native Realtime route.
///
/// This contract is an App Shell adapter boundary. Feature code should consume
/// `network_sdk.RealtimeSession`, not this native event/control shape.
abstract interface class NetworkRealtimeGateway {
  /// Native typed state/signaling events. Signaling events stay inside the
  /// App/adapter and are never forwarded to a Feature.
  Stream<NativeNetworkEvent> get events;

  /// Queues a native start command. Success means accepted by the native
  /// command queue; the eventual session state arrives through [events].
  NativeOperationStatus start({
    required String realtimeId,
    required String peerId,
  });

  /// Queues a native stop command. Success means accepted by the native
  /// command queue; `closed` is reported asynchronously through [events].
  NativeOperationStatus stop({required String realtimeId});
}

/// Runtime-owned implementation backed by a borrowed command gateway.
final class RuntimeNetworkRealtimeGateway implements NetworkRealtimeGateway {
  RuntimeNetworkRealtimeGateway(this._gateway);

  final NetworkCommandGateway _gateway;
  int _commandSequence = 0;

  @override
  Stream<NativeNetworkEvent> get events => _gateway.events
      .map(_decodeEvent)
      .where((event) => event != null)
      .cast<NativeNetworkEvent>();

  @override
  NativeOperationStatus start({
    required String realtimeId,
    required String peerId,
  }) {
    try {
      return _send(
        NativeNetworkProtocol.startRealtimeSessionCommand(
          commandId: _nextCommandId('realtime-start'),
          realtimeId: realtimeId,
          peerId: peerId,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  @override
  NativeOperationStatus stop({required String realtimeId}) {
    try {
      return _send(
        NativeNetworkProtocol.stopRealtimeSessionCommand(
          commandId: _nextCommandId('realtime-stop'),
          realtimeId: realtimeId,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  NativeOperationStatus _send(Uint8List command) =>
      switch (_gateway.sendCommand(command)) {
        TransportOperationStatus.success => NativeOperationStatus.success,
        TransportOperationStatus.invalidArgument =>
          NativeOperationStatus.invalidArgument,
        TransportOperationStatus.stopped => NativeOperationStatus.stopped,
        TransportOperationStatus.failure => NativeOperationStatus.failure,
      };

  String _nextCommandId(String operation) {
    _commandSequence = (_commandSequence + 1) & 0x7fffffff;
    return '$operation-${DateTime.now().microsecondsSinceEpoch}-$_commandSequence';
  }

  static NativeNetworkEvent? _decodeEvent(Uint8List bytes) {
    try {
      return NativeNetworkProtocol.decodeEvent(bytes);
    } on FormatException {
      return null;
    }
  }
}
