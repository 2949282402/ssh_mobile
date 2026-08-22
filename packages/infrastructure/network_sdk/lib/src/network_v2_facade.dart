part of 'network_v2.dart';

/// Public v2 facade lifecycle states.
enum NetworkV2LifecycleState { created, running, stopping, stopped, disposed }

/// Feature-facing v2 facade.  It owns no native resource; the injected port
/// remains the App/native lifecycle owner.
abstract interface class NetworkV2Facade {
  NetworkV2LifecycleState get lifecycle;
  Stream<NetworkV2Event> get events;

  Future<void> start();

  Future<void> stop();

  Future<CommandResult<void>> connectPeer(ConnectPeerRequest request);

  Future<CommandResult<void>> disconnectPeer(DisconnectPeerRequest request);

  Future<CommandResult<void>> removePeer(RemovePeerRequest request);

  Future<CommandResult<PeerDiagnostics>> peerDiagnostics(
    PeerDiagnosticsRequest request,
  );

  Future<CommandResult<void>> sendMessage(SendMessageRequest request);

  Future<CommandResult<void>> transferFile(TransferFileRequest request);

  Future<CommandResult<void>> openStream(OpenStreamRequest request);

  /// Releases facade subscriptions/state only. The injected command port is
  /// owned by the App/native composition root and remains usable by its owner.
  Future<void> dispose();
}

/// Small adapter that keeps lifecycle and command correlation out of Features.
/// Domain adapters are injected internally so each function domain has an
/// explicit ownership boundary without changing the public V2 method names.
final class NetworkV2FacadeImpl implements NetworkV2Facade {
  NetworkV2FacadeImpl(NetworkV2CommandPort port)
    : _port = port,
      _connection = NetworkV2ConnectionPortAdapter(port),
      _identity = NetworkV2IdentityPortAdapter(port),
      _transfer = NetworkV2TransferPortAdapter(port),
      _realtime = NetworkV2RealtimePortAdapter(port),
      _relay = NetworkV2RelayPortAdapter(port);

  final NetworkV2CommandPort _port;
  final NetworkV2ConnectionPort _connection;
  final NetworkV2IdentityPort _identity;
  final NetworkV2TransferPort _transfer;
  final NetworkV2RealtimePort _realtime;
  final NetworkV2RelayPort _relay;
  NetworkV2LifecycleState _lifecycle = NetworkV2LifecycleState.created;
  bool _disposing = false;

  @override
  NetworkV2LifecycleState get lifecycle => _lifecycle;

  @override
  Stream<NetworkV2Event> get events => _port.events;

  @override
  Future<void> start() async {
    _ensureNotDisposed();
    if (_lifecycle == NetworkV2LifecycleState.running) return;
    if (_lifecycle == NetworkV2LifecycleState.stopping) {
      throw StateError('Network v2 facade is stopping.');
    }
    await _relay.start();
    _lifecycle = NetworkV2LifecycleState.running;
  }

  @override
  Future<void> stop() async {
    _ensureNotDisposed();
    if (_lifecycle == NetworkV2LifecycleState.stopped ||
        _lifecycle == NetworkV2LifecycleState.created) {
      _lifecycle = NetworkV2LifecycleState.stopped;
      return;
    }
    if (_lifecycle == NetworkV2LifecycleState.stopping) return;
    _lifecycle = NetworkV2LifecycleState.stopping;
    try {
      await _relay.stop();
    } finally {
      _lifecycle = NetworkV2LifecycleState.stopped;
    }
  }

  @override
  Future<CommandResult<void>> connectPeer(ConnectPeerRequest request) {
    _ensureRunning();
    return _connection.connectPeer(request);
  }

  @override
  Future<CommandResult<void>> disconnectPeer(DisconnectPeerRequest request) {
    _ensureRunning();
    return _connection.disconnectPeer(request);
  }

  @override
  Future<CommandResult<void>> removePeer(RemovePeerRequest request) {
    _ensureRunning();
    return _identity.removePeer(request);
  }

  @override
  Future<CommandResult<PeerDiagnostics>> peerDiagnostics(
    PeerDiagnosticsRequest request,
  ) {
    _ensureRunning();
    return _connection.peerDiagnostics(request);
  }

  @override
  Future<CommandResult<void>> sendMessage(SendMessageRequest request) {
    _ensureRunning();
    return _realtime.sendMessage(request);
  }

  @override
  Future<CommandResult<void>> transferFile(TransferFileRequest request) {
    _ensureRunning();
    return _transfer.transferFile(request);
  }

  @override
  Future<CommandResult<void>> openStream(OpenStreamRequest request) {
    _ensureRunning();
    return _realtime.openStream(request);
  }

  @override
  Future<void> dispose() async {
    if (_disposing || _lifecycle == NetworkV2LifecycleState.disposed) return;
    _disposing = true;
    // The facade is a borrower. Do not stop or dispose the injected port here:
    // the App/native owner controls that resource and may have other users.
    _lifecycle = NetworkV2LifecycleState.disposed;
  }

  void _ensureNotDisposed() {
    if (_lifecycle == NetworkV2LifecycleState.disposed) {
      throw const SdkClientDisposedException();
    }
  }

  void _ensureRunning() {
    _ensureNotDisposed();
    if (_lifecycle != NetworkV2LifecycleState.running) {
      throw StateError('Network v2 facade is not running.');
    }
  }
}
