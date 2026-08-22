part of 'network_v2.dart';

/// Typed command boundary owned by the App/native adapter.
///
/// The port is an adapter boundary, not a Feature-owned runtime. Its
/// [dispose] method is reserved for the App/native owner; the feature-facing
/// facade never calls it.
abstract interface class NetworkV2CommandPort {
  Stream<NetworkV2Event> get events;

  Future<void> start();

  Future<void> stop();

  Future<CommandResult<T>> execute<T>(PeerScopedRequest request);

  Future<CommandResult<PeerDiagnostics>> diagnostics(String peerId);

  /// Releases resources owned by the App/native adapter.
  ///
  /// A [NetworkV2Facade] borrower must not invoke this method.
  Future<void> dispose();
}

/// Connection-domain operations.  Route selection, PathLease, and transport
/// details remain below this contract.
abstract interface class NetworkV2ConnectionPort {
  Future<CommandResult<void>> connectPeer(ConnectPeerRequest request);

  Future<CommandResult<void>> disconnectPeer(DisconnectPeerRequest request);

  Future<CommandResult<PeerDiagnostics>> peerDiagnostics(
    PeerDiagnosticsRequest request,
  );
}

/// Identity-domain lifecycle. Removing a peer includes local trust/config
/// cleanup and is intentionally separate from disconnecting a live path.
abstract interface class NetworkV2IdentityPort {
  Future<CommandResult<void>> removePeer(RemovePeerRequest request);
}

/// Transfer-domain operations. Progress and transfer events stay on the
/// shared typed event stream rather than leaking a carrier implementation.
abstract interface class NetworkV2TransferPort {
  Future<CommandResult<void>> transferFile(TransferFileRequest request);
}

/// Realtime/data-channel operations exposed by the frozen V2 contract.
abstract interface class NetworkV2RealtimePort {
  Future<CommandResult<void>> sendMessage(SendMessageRequest request);

  Future<CommandResult<void>> openStream(OpenStreamRequest request);
}

/// Relay-domain lifecycle bridge. It changes runtime availability only; it
/// does not own a Peer, connection, socket, credential, or PathLease.
abstract interface class NetworkV2RelayPort {
  Future<void> start();

  Future<void> stop();
}

final class NetworkV2ConnectionPortAdapter implements NetworkV2ConnectionPort {
  const NetworkV2ConnectionPortAdapter(this._commands);

  final NetworkV2CommandPort _commands;

  @override
  Future<CommandResult<void>> connectPeer(ConnectPeerRequest request) =>
      _commands.execute<void>(request);

  @override
  Future<CommandResult<void>> disconnectPeer(DisconnectPeerRequest request) =>
      _commands.execute<void>(request);

  @override
  Future<CommandResult<PeerDiagnostics>> peerDiagnostics(
    PeerDiagnosticsRequest request,
  ) => _commands.diagnostics(request.peerId);
}

final class NetworkV2IdentityPortAdapter implements NetworkV2IdentityPort {
  const NetworkV2IdentityPortAdapter(this._commands);

  final NetworkV2CommandPort _commands;

  @override
  Future<CommandResult<void>> removePeer(RemovePeerRequest request) =>
      _commands.execute<void>(request);
}

final class NetworkV2TransferPortAdapter implements NetworkV2TransferPort {
  const NetworkV2TransferPortAdapter(this._commands);

  final NetworkV2CommandPort _commands;

  @override
  Future<CommandResult<void>> transferFile(TransferFileRequest request) =>
      _commands.execute<void>(request);
}

final class NetworkV2RealtimePortAdapter implements NetworkV2RealtimePort {
  const NetworkV2RealtimePortAdapter(this._commands);

  final NetworkV2CommandPort _commands;

  @override
  Future<CommandResult<void>> sendMessage(SendMessageRequest request) =>
      _commands.execute<void>(request);

  @override
  Future<CommandResult<void>> openStream(OpenStreamRequest request) =>
      _commands.execute<void>(request);
}

final class NetworkV2RelayPortAdapter implements NetworkV2RelayPort {
  const NetworkV2RelayPortAdapter(this._commands);

  final NetworkV2CommandPort _commands;

  @override
  Future<void> start() => _commands.start();

  @override
  Future<void> stop() => _commands.stop();
}
