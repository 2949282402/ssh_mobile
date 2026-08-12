import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

import 'package:ssh_mobile/app/realtime_feature_adapters.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';

  test(
    'start queue success followed by native failure completes as failure',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      final commandId = gateway.lastStartCommandId!;
      gateway.emitCommandResult(
        commandId: commandId,
        accepted: false,
        error: const NativeNetworkError(
          code: 8,
          message: 'relay unavailable',
          operation: 'start_realtime_session',
        ),
      );

      final result = await startFuture;
      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.relayError,
      );
      expect(session.state, RealtimeSessionState.failed);
      await client.dispose();
    },
  );

  test(
    'queue rejection returns immediately without waiting for a result',
    () async {
      final gateway = _FakeRealtimeGateway(
        startStatus: NativeOperationStatus.stopped,
      );
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final result = await session.start();

      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.cancelled,
      );
      expect(gateway.lastStartCommandId, isNotNull);
      await client.dispose();
    },
  );

  test(
    'start completion does not advance state before native state events',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      expect(await startFuture, isA<SdkSuccess<void>>());
      expect(session.state, RealtimeSessionState.starting);

      gateway.emitState(NativeRealtimeSessionState.negotiating);
      gateway.emitState(NativeRealtimeSessionState.connected);
      await _pump();
      expect(session.state, RealtimeSessionState.connected);
      await client.dispose();
    },
  );

  test('stop command completion waits for the native closed state', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    final startFuture = session.start();
    await _pump();
    gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
    await startFuture;
    gateway.emitState(NativeRealtimeSessionState.connected);
    await _pump();

    final stopFuture = session.stop();
    await _pump();
    gateway.emitCommandResult(commandId: gateway.lastStopCommandId!);
    expect(await stopFuture, isA<SdkSuccess<void>>());
    expect(session.state, RealtimeSessionState.connected);

    gateway.emitState(NativeRealtimeSessionState.closed);
    await _pump();
    expect(session.state, RealtimeSessionState.stopped);
    await client.dispose();
  });

  test(
    'missing command result times out and removes the pending command',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(milliseconds: 10),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final timedOut = await session.start();
      expect(timedOut, isA<SdkFailure<void>>());
      expect(
        (timedOut as SdkFailure<void>).error.code,
        NetworkErrorCode.timeout,
      );

      final secondStart = session.start();
      await _pump();
      gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
      expect(await secondStart, isA<SdkSuccess<void>>());
      await client.dispose();
    },
  );

  test('pending command capacity rejects new native work', () async {
    final gateway = _FakeRealtimeGateway();
    final backend = AppRealtimeSessionBackend(
      networkRuntime: _FakeNetworkRuntime(gateway),
      maxPendingCommands: 1,
      commandResultTimeout: const Duration(seconds: 1),
    );
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
    );

    final startFuture = session.start();
    await _pump();
    final rejectedStop = await session.stop();
    expect(rejectedStop, isA<SdkFailure<void>>());
    expect(
      (rejectedStop as SdkFailure<void>).error.code,
      NetworkErrorCode.ioError,
    );

    gateway.emitCommandResult(commandId: gateway.lastStartCommandId!);
    expect(await startFuture, isA<SdkSuccess<void>>());
    await client.dispose();
  });

  test(
    'dispose cancels pending commands and ignores late native results',
    () async {
      final gateway = _FakeRealtimeGateway();
      final backend = AppRealtimeSessionBackend(
        networkRuntime: _FakeNetworkRuntime(gateway),
        commandResultTimeout: const Duration(seconds: 1),
      );
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: realtimeId,
        peerId: 'peer-a',
      );

      final startFuture = session.start();
      await _pump();
      final commandId = gateway.lastStartCommandId!;
      await client.dispose();

      final result = await startFuture;
      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.cancelled,
      );
      expect(session.state, RealtimeSessionState.stopped);

      gateway.emitCommandResult(commandId: commandId);
      gateway.emitState(NativeRealtimeSessionState.connected);
      await _pump();
      expect(session.state, RealtimeSessionState.stopped);
    },
  );
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

final class _FakeNetworkRuntime implements NetworkRuntime {
  _FakeNetworkRuntime(this.gateway);

  final NetworkRealtimeGateway gateway;

  @override
  NetworkRuntimeState get state => NetworkRuntimeState.ready;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 1,
    readyCapabilities: const <NetworkCapability>[NetworkCapability.realtime],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {}

  @override
  bool isCapabilityReady(NetworkCapability capability) => true;

  @override
  Future<NetworkCommandGateway> openCommandGateway() =>
      throw UnimplementedError();

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async => gateway;

  @override
  Future<void> dispose() async {}
}

final class _FakeRealtimeGateway implements NetworkRealtimeGateway {
  _FakeRealtimeGateway({this.startStatus = NativeOperationStatus.success});

  final StreamController<NativeNetworkEvent> _events =
      StreamController<NativeNetworkEvent>.broadcast();
  final NativeOperationStatus startStatus;
  int _sequence = 0;
  String? lastStartCommandId;
  String? lastStopCommandId;

  @override
  Stream<NativeNetworkEvent> get events => _events.stream;

  @override
  NativeCommandTicket start({
    required String realtimeId,
    required String peerId,
  }) {
    final commandId = 'start-${++_sequence}';
    lastStartCommandId = commandId;
    return NativeCommandTicket(commandId: commandId, queueStatus: startStatus);
  }

  @override
  NativeCommandTicket stop({required String realtimeId}) {
    final commandId = 'stop-${++_sequence}';
    lastStopCommandId = commandId;
    return NativeCommandTicket(
      commandId: commandId,
      queueStatus: NativeOperationStatus.success,
    );
  }

  void emitCommandResult({
    required String commandId,
    bool accepted = true,
    NativeNetworkError? error,
  }) {
    _events.add(
      NativeCommandResultEvent(
        eventId: 'event-$commandId',
        timestampMs: 1,
        protocolVersion: 1,
        commandId: commandId,
        accepted: accepted,
        error: error,
      ),
    );
  }

  void emitState(NativeRealtimeSessionState state) {
    _events.add(
      NativeRealtimeStateChangedEvent(
        eventId: 'state-${++_sequence}',
        timestampMs: 1,
        protocolVersion: 1,
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: state,
        revision: _sequence,
      ),
    );
  }
}
