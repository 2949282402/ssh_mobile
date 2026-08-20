import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'network_models.dart';

/// Hard limits shared by the v2-facing Flutter contract.
///
/// These limits are deliberately expressed in bytes/items rather than in
/// transport terms.  A Feature can therefore use this contract without
/// knowing whether a request is carried by QUIC, TCP, WebSocket, or Relay.
final class NetworkV2Limits {
  const NetworkV2Limits._();

  static const int maxCommandIdBytes = 128;
  static const int maxEventIdBytes = 256;
  static const int maxPeerIdBytes = 128;
  static const int maxMessagePayloadBytes = 1024 * 1024;
  static const int maxStreamChunkBytes = 64 * 1024;
  static const int maxEventBytes = 1024 * 1024;
  static const int maxControlItems = 256;
  static const int maxControlBytes = 4 * 1024 * 1024;
  static const int maxDataItems = 128;
  static const int maxDataBytes = 8 * 1024 * 1024;
  static const int maxConsecutiveControlEvents = 8;
  static const int maxPeerCounters = 64;
  static const int maxTransferIdBytes = 128;
  static const int maxMessageIdBytes = 128;
  static const int maxStreamOpenerIdBytes = 128;
  static const int maxFilePathBytes = 1024 * 1024;
  static const int maxPendingCommands = 64;
}

/// Application-level encryption policy.
///
/// `disabled` is a deliberate direct-only opt-out.  A relay-capable adapter
/// must reject it instead of silently downgrading to a relay connection.
enum E2eePolicy {
  required(0),
  disabled(1);

  const E2eePolicy(this.wireValue);

  /// Stable policy value for the peer/path security contract. Application
  /// messages do not carry a per-message crypto-mode field; native always
  /// applies the ConnectionSession E2EE context.
  final int wireValue;

  bool get relayCompatible => this == E2eePolicy.required;
}

/// Logical Peer lifecycle exposed to Flutter.
///
/// This is intentionally smaller than native connection/session states.
enum PeerState { offline, connecting, online }

/// Terminal state of one public command.
enum CommandTerminalState { succeeded, failed, cancelled }

/// Event scheduling lane at the Flutter contract boundary.
enum NetworkEventLane { control, data }

/// Scheduling priority within the bounded event mux.
enum NetworkEventPriority { criticalControl, normalControl, data }

/// A copied, bounded application payload.
final class NetworkPayload {
  NetworkPayload(
    Uint8List bytes, {
    this.maxBytes = NetworkV2Limits.maxMessagePayloadBytes,
  }) : _bytes = _copyAndValidate(bytes, maxBytes);

  final int maxBytes;
  final Uint8List _bytes;

  /// Returns a fresh copy so callers cannot mutate the value held by the
  /// contract or an in-flight command.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  int get length => _bytes.length;

  static Uint8List _copyAndValidate(Uint8List bytes, int maxBytes) {
    if (maxBytes < 0 || bytes.length > maxBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'Payload must contain at most $maxBytes bytes.',
      );
    }
    return Uint8List.fromList(bytes);
  }
}

/// Base class for every v2 request that targets one Peer.
sealed class PeerScopedRequest {
  PeerScopedRequest({required String peerId})
    : peerId = _validatePeerId(peerId);

  final String peerId;

  static String _validatePeerId(String value) {
    if (value.isEmpty || value.length > NetworkV2Limits.maxPeerIdBytes) {
      throw ArgumentError.value(
        value,
        'peerId',
        'Peer ID must contain 1-${NetworkV2Limits.maxPeerIdBytes} characters.',
      );
    }
    return value;
  }
}

/// Requests that make a Peer maintain a usable path.
final class ConnectPeerRequest extends PeerScopedRequest {
  ConnectPeerRequest({
    required super.peerId,
    this.e2eePolicy = E2eePolicy.required,
    this.config,
  });

  final E2eePolicy e2eePolicy;
  final NetworkV2PeerConfig? config;
}

/// Immutable peer configuration carried across the V2 boundary.
final class NetworkV2PeerConfig {
  NetworkV2PeerConfig({
    required String peerId,
    required this.endpointAddress,
    required Uint8List identityPublicKey,
    required Uint8List e2ePublicKey,
    this.e2eePolicy = E2eePolicy.required,
  }) : peerId = _validateIdentifier(
         peerId,
         'peerId',
         NetworkV2Limits.maxPeerIdBytes,
       ),
       identityPublicKey = Uint8List.fromList(identityPublicKey),
       e2ePublicKey = Uint8List.fromList(e2ePublicKey);

  final String peerId;
  final String endpointAddress;
  final Uint8List identityPublicKey;
  final Uint8List e2ePublicKey;
  final E2eePolicy e2eePolicy;
}

/// Requests that stop a Peer without deleting its trust/configuration.
final class DisconnectPeerRequest extends PeerScopedRequest {
  DisconnectPeerRequest({required super.peerId});
}

/// Requests that remove all local Peer configuration and trust state.
final class RemovePeerRequest extends PeerScopedRequest {
  RemovePeerRequest({required super.peerId});
}

/// Requests a bounded reliable application message.
final class SendMessageRequest extends PeerScopedRequest {
  SendMessageRequest({
    required super.peerId,
    required String messageId,
    required Uint8List payload,
    this.e2eePolicy = E2eePolicy.required,
  }) : messageId = _validateIdentifier(
         messageId,
         'messageId',
         NetworkV2Limits.maxMessageIdBytes,
       ),
       payload = NetworkPayload(payload);

  final String messageId;
  final NetworkPayload payload;
  final E2eePolicy e2eePolicy;
}

/// Requests one bounded transfer attempt.  The transfer ID is not a Peer ID;
/// callers must keep the `(peerId, transferId)` identity pair intact.
final class TransferFileRequest extends PeerScopedRequest {
  TransferFileRequest({
    required super.peerId,
    required String transferId,
    required String filePath,
  }) : transferId = _validateIdentifier(
         transferId,
         'transferId',
         NetworkV2Limits.maxTransferIdBytes,
       ),
       filePath = _validateIdentifier(
         filePath,
         'filePath',
         NetworkV2Limits.maxFilePathBytes,
       );

  final String transferId;
  final String filePath;
}

/// Requests a stream operation while keeping stream identity separate from
/// message and transfer identities.
final class OpenStreamRequest extends PeerScopedRequest {
  OpenStreamRequest({
    required super.peerId,
    required String openerDeviceId,
    required this.streamId,
  }) : openerDeviceId = _validateIdentifier(
         openerDeviceId,
         'openerDeviceId',
         NetworkV2Limits.maxStreamOpenerIdBytes,
       ) {
    if (streamId < 1 || streamId > 0xffff) {
      throw ArgumentError.value(streamId, 'streamId', 'Must be in 1..65535.');
    }
  }

  final String openerDeviceId;
  final int streamId;
}

/// Requests a read-only, Peer-scoped diagnostic snapshot.
final class PeerDiagnosticsRequest extends PeerScopedRequest {
  PeerDiagnosticsRequest({required super.peerId});
}

/// A terminal result correlated to exactly one public command ID.
final class CommandResult<T> {
  const CommandResult._({
    required this.commandId,
    required this.state,
    this.peerId,
    this.value,
    this.error,
  });

  factory CommandResult.success({
    required String commandId,
    String? peerId,
    T? value,
  }) => CommandResult<T>._(
    commandId: _validateCommandId(commandId),
    peerId: peerId,
    state: CommandTerminalState.succeeded,
    value: value,
  );

  factory CommandResult.failure({
    required String commandId,
    required NetworkError error,
    String? peerId,
  }) => CommandResult<T>._(
    commandId: _validateCommandId(commandId),
    peerId: peerId,
    state: CommandTerminalState.failed,
    error: error,
  );

  factory CommandResult.cancelled({
    required String commandId,
    required NetworkError error,
    String? peerId,
  }) => CommandResult<T>._(
    commandId: _validateCommandId(commandId),
    peerId: peerId,
    state: CommandTerminalState.cancelled,
    error: error,
  );

  final String commandId;
  final String? peerId;
  final CommandTerminalState state;
  final T? value;
  final NetworkError? error;

  bool get isTerminal => true;
  bool get isSuccess => state == CommandTerminalState.succeeded;
  bool get isCancelled => state == CommandTerminalState.cancelled;

  static String _validateCommandId(String value) {
    if (value.isEmpty || value.length > NetworkV2Limits.maxCommandIdBytes) {
      throw ArgumentError.value(
        value,
        'commandId',
        'Command ID must contain 1-${NetworkV2Limits.maxCommandIdBytes} characters.',
      );
    }
    return value;
  }
}

/// A result projected back into a Peer-scoped API.
final class PeerScopedResult<T> {
  const PeerScopedResult({required this.peerId, required this.result});

  final String peerId;
  final CommandResult<T> result;
}

/// Owns the one terminal completion slot for a command.
///
/// Duplicate native results, late results after cancellation, and repeated
/// shutdown completion attempts return `false` and do not complete the Future
/// a second time.
final class CommandResultCompleter<T> {
  CommandResultCompleter({required this.commandId, this.peerId})
    : _future = Completer<CommandResult<T>>();

  final String commandId;
  final String? peerId;
  final Completer<CommandResult<T>> _future;

  Future<CommandResult<T>> get future => _future.future;
  bool get isCompleted => _future.isCompleted;

  bool complete(CommandResult<T> result) {
    if (_future.isCompleted || result.commandId != commandId) return false;
    _future.complete(result);
    return true;
  }
}

/// Registry for public command terminal results.
final class CommandResultTracker {
  CommandResultTracker({
    this.maxPendingCommands = NetworkV2Limits.maxPendingCommands,
  }) : assert(maxPendingCommands > 0);

  final int maxPendingCommands;
  final Map<String, CommandResultCompleter<Object?>> _pending =
      <String, CommandResultCompleter<Object?>>{};

  int get pendingCount => _pending.length;

  CommandResultCompleter<T> register<T>({
    required String commandId,
    String? peerId,
  }) {
    if (_pending.length >= maxPendingCommands) {
      throw StateError('Network V2 command resource limit reached.');
    }
    if (_pending.containsKey(commandId)) {
      throw StateError('Command ID is already pending: $commandId');
    }
    final completer = CommandResultCompleter<T>(
      commandId: commandId,
      peerId: peerId,
    );
    _pending[commandId] = completer as CommandResultCompleter<Object?>;
    return completer;
  }

  /// Completes and removes a pending command.  Returns false for duplicates,
  /// unknown IDs, and results that arrived after cancellation.
  bool complete<T>(CommandResult<T> result) {
    final completer = _pending[result.commandId];
    if (completer == null) return false;
    if (completer.peerId != null && completer.peerId != result.peerId) {
      return false;
    }
    final didComplete = completer.complete(result as CommandResult<Object?>);
    if (didComplete) _pending.remove(result.commandId);
    return didComplete;
  }

  bool cancel(String commandId, {NetworkError? error}) {
    final completer = _pending.remove(commandId);
    if (completer == null) return false;
    completer.complete(
      CommandResult<Object?>.cancelled(
        commandId: commandId,
        peerId: completer.peerId,
        error:
            error ??
            const NetworkError(
              code: NetworkErrorCode.cancelled,
              message: 'command cancelled',
            ),
      ),
    );
    return true;
  }

  /// Completes every pending command once during an owned shutdown.
  void cancelAll({required NetworkError error}) {
    final pending = List<CommandResultCompleter<Object?>>.from(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      completer.complete(
        CommandResult<Object?>.cancelled(
          commandId: completer.commandId,
          peerId: completer.peerId,
          error: error,
        ),
      );
    }
  }
}

/// Abstract environment input owned by the host/platform layer.
final class NetworkEnvironment {
  const NetworkEnvironment({
    required this.generation,
    required this.hasConnectivity,
    required this.isForeground,
    this.isMetered = false,
  }) : assert(generation >= 0);

  final int generation;
  final bool hasConnectivity;
  final bool isForeground;
  final bool isMetered;
}

/// A typed host environment event.  It deliberately contains no socket,
/// interface, ICE, SDP, or platform object.
final class NetworkEnvironmentChanged extends NetworkV2Event {
  const NetworkEnvironmentChanged({
    required super.eventId,
    required super.timestamp,
    required this.environment,
  }) : super(
         lane: NetworkEventLane.control,
         priority: NetworkEventPriority.normalControl,
       );

  final NetworkEnvironment environment;
}

/// A bounded, transport-neutral Peer diagnostic snapshot.
final class PeerDiagnostics {
  const PeerDiagnostics({
    required this.peerId,
    required this.state,
    required this.e2eePolicy,
    this.readyPathCount = 0,
    this.queuedCommandCount = 0,
    this.activeStreamCount = 0,
    this.activeTransferCount = 0,
    this.lastError,
  }) : assert(readyPathCount >= 0),
       assert(queuedCommandCount >= 0),
       assert(activeStreamCount >= 0),
       assert(activeTransferCount >= 0),
       assert(readyPathCount <= NetworkV2Limits.maxPeerCounters),
       assert(queuedCommandCount <= NetworkV2Limits.maxPeerCounters),
       assert(activeStreamCount <= NetworkV2Limits.maxPeerCounters),
       assert(activeTransferCount <= NetworkV2Limits.maxPeerCounters);

  final String peerId;
  final PeerState state;
  final E2eePolicy e2eePolicy;
  final int readyPathCount;
  final int queuedCommandCount;
  final int activeStreamCount;
  final int activeTransferCount;
  final NetworkError? lastError;
}

/// Applies the frozen public error precedence. Transport details are only
/// fallback diagnostics and can never replace an authoritative business error.
NetworkError? resolvePublicNetworkError({
  NetworkError? configOrSecurity,
  NetworkError? peerStatus,
  NetworkError? resourceOrLifecycle,
  NetworkError? timeout,
  NetworkError? noRoute,
}) =>
    configOrSecurity ?? peerStatus ?? resourceOrLifecycle ?? timeout ?? noRoute;

/// Base class for v2-facing typed events.
sealed class NetworkV2Event {
  const NetworkV2Event({
    required this.eventId,
    required this.timestamp,
    required this.lane,
    required this.priority,
    this.peerId,
  });

  final String eventId;
  final DateTime timestamp;
  final NetworkEventLane lane;
  final NetworkEventPriority priority;
  final String? peerId;
}

/// Exactly-once terminal command event.
final class CommandResultEvent<T> extends NetworkV2Event {
  CommandResultEvent({
    required super.eventId,
    required super.timestamp,
    required this.result,
  }) : super(
         peerId: result.peerId,
         lane: NetworkEventLane.control,
         priority: NetworkEventPriority.criticalControl,
       );

  final CommandResult<T> result;
}

/// Peer lifecycle event with no native route/socket details.
final class PeerStateChangedEvent extends NetworkV2Event {
  const PeerStateChangedEvent({
    required super.eventId,
    required super.timestamp,
    required super.peerId,
    required this.state,
    this.e2eePolicy = E2eePolicy.required,
    this.error,
  }) : super(
         lane: NetworkEventLane.control,
         priority: NetworkEventPriority.criticalControl,
       );

  final PeerState state;
  final E2eePolicy e2eePolicy;
  final NetworkError? error;
}

/// Peer-scoped diagnostics event.
final class PeerDiagnosticsChangedEvent extends NetworkV2Event {
  PeerDiagnosticsChangedEvent({
    required super.eventId,
    required super.timestamp,
    required this.diagnostics,
  }) : super(
         peerId: diagnostics.peerId,
         lane: NetworkEventLane.control,
         priority: NetworkEventPriority.normalControl,
       );

  final PeerDiagnostics diagnostics;
}

/// Peer-scoped reliable message event.
final class PeerMessageEvent extends NetworkV2Event {
  PeerMessageEvent({
    required super.eventId,
    required super.timestamp,
    required super.peerId,
    required this.messageId,
    required Uint8List payload,
  }) : payload = NetworkPayload(payload),
       super(lane: NetworkEventLane.data, priority: NetworkEventPriority.data);

  final String messageId;
  final NetworkPayload payload;
}

/// Peer-scoped transfer progress event.
final class PeerTransferProgressEvent extends NetworkV2Event {
  const PeerTransferProgressEvent({
    required super.eventId,
    required super.timestamp,
    required super.peerId,
    required this.transferId,
    required this.bytesTransferred,
    required this.totalBytes,
  }) : super(lane: NetworkEventLane.data, priority: NetworkEventPriority.data);

  final String transferId;
  final int bytesTransferred;
  final int totalBytes;
}

/// Peer-scoped bounded stream data event.
final class PeerStreamDataEvent extends NetworkV2Event {
  PeerStreamDataEvent({
    required super.eventId,
    required super.timestamp,
    required super.peerId,
    required this.openerDeviceId,
    required this.streamId,
    required Uint8List data,
  }) : data = NetworkPayload(
         data,
         maxBytes: NetworkV2Limits.maxStreamChunkBytes,
       ),
       super(lane: NetworkEventLane.data, priority: NetworkEventPriority.data);

  final String openerDeviceId;
  final int streamId;
  final NetworkPayload data;
}

/// Typed command boundary owned by the App/native adapter.
///
/// Implementations may map supported requests to the frozen Network Protocol
/// V2 wire, but they must return an explicit failure for requests whose schema
/// is not yet owned by the Coordinator. They must never expose the native
/// handle or socket.
abstract interface class NetworkV2CommandPort {
  Stream<NetworkV2Event> get events;

  Future<void> start();

  Future<void> stop();

  Future<CommandResult<T>> execute<T>(PeerScopedRequest request);

  Future<CommandResult<PeerDiagnostics>> diagnostics(String peerId);

  Future<void> dispose();
}

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

  Future<void> dispose();
}

/// Small adapter that keeps lifecycle and command correlation out of Features.
final class NetworkV2FacadeImpl implements NetworkV2Facade {
  NetworkV2FacadeImpl(this._port);

  final NetworkV2CommandPort _port;
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
    await _port.start();
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
      await _port.stop();
    } finally {
      _lifecycle = NetworkV2LifecycleState.stopped;
    }
  }

  @override
  Future<CommandResult<void>> connectPeer(ConnectPeerRequest request) =>
      _execute<void>(request);

  @override
  Future<CommandResult<void>> disconnectPeer(DisconnectPeerRequest request) =>
      _execute<void>(request);

  @override
  Future<CommandResult<void>> removePeer(RemovePeerRequest request) =>
      _execute<void>(request);

  @override
  Future<CommandResult<PeerDiagnostics>> peerDiagnostics(
    PeerDiagnosticsRequest request,
  ) async {
    _ensureRunning();
    return _port.diagnostics(request.peerId);
  }

  @override
  Future<CommandResult<void>> sendMessage(SendMessageRequest request) =>
      _execute<void>(request);

  @override
  Future<CommandResult<void>> transferFile(TransferFileRequest request) =>
      _execute<void>(request);

  @override
  Future<CommandResult<void>> openStream(OpenStreamRequest request) =>
      _execute<void>(request);

  @override
  Future<void> dispose() async {
    if (_disposing || _lifecycle == NetworkV2LifecycleState.disposed) return;
    _disposing = true;
    _lifecycle = NetworkV2LifecycleState.stopping;
    try {
      await _port.stop();
    } finally {
      await _port.dispose();
      _lifecycle = NetworkV2LifecycleState.disposed;
    }
  }

  Future<CommandResult<T>> _execute<T>(PeerScopedRequest request) async {
    _ensureRunning();
    return _port.execute<T>(request);
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

String _validateIdentifier(String value, String name, int maxBytes) {
  final length = utf8.encode(value).length;
  if (value.isEmpty || length > maxBytes) {
    throw ArgumentError.value(
      value,
      name,
      'Must contain 1-$maxBytes UTF-8 bytes.',
    );
  }
  return value;
}
