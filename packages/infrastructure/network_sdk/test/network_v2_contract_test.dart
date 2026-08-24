import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test('v2 requests are Peer-scoped and copy bounded payloads', () {
    final source = Uint8List.fromList(<int>[1, 2, 3]);
    final request = SendMessageRequest(
      peerId: 'peer-a',
      messageId: 'message-a',
      payload: source,
      e2eePolicy: E2eePolicy.required,
    );
    source[0] = 9;

    expect(request.peerId, 'peer-a');
    expect(request.payload.bytes, orderedEquals(<int>[1, 2, 3]));
    expect(request.e2eePolicy.relayCompatible, isTrue);
    expect(
      () => SendMessageRequest(
        peerId: 'peer-a',
        messageId: 'message-a',
        payload: Uint8List(NetworkV2Limits.maxMessagePayloadBytes + 1),
      ),
      throwsArgumentError,
    );
    expect(
      () => ConnectPeerRequest(
        peerId: 'p' * (NetworkV2Limits.maxPeerIdBytes + 1),
      ),
      throwsArgumentError,
    );
  });

  test('CommandResultTracker completes a command exactly once', () async {
    final tracker = CommandResultTracker();
    final completer = tracker.register<void>(
      commandId: 'command-a',
      peerId: 'peer-a',
    );

    final result = CommandResult<void>.success(
      commandId: 'command-a',
      peerId: 'peer-a',
    );
    expect(tracker.complete(result), isTrue);
    expect(tracker.complete(result), isFalse);
    expect((await completer.future).isSuccess, isTrue);
    expect(tracker.pendingCount, 0);
  });

  test(
    'shutdown cancellation is terminal and duplicate completion is ignored',
    () async {
      final tracker = CommandResultTracker();
      final completer = tracker.register<void>(commandId: 'command-a');
      tracker.cancelAll(
        error: const NetworkError(
          code: NetworkErrorCode.cancelled,
          message: 'runtime stopped',
        ),
      );

      final result = await completer.future;
      expect(result.isCancelled, isTrue);
      expect(
        tracker.complete(CommandResult<void>.success(commandId: 'command-a')),
        isFalse,
      );
    },
  );

  test(
    'NetworkEnvironmentChanged and diagnostics contain abstract fields only',
    () {
      const environment = NetworkEnvironment(
        generation: 4,
        hasConnectivity: true,
        isForeground: false,
        isMetered: true,
      );
      final event = NetworkEnvironmentChanged(
        eventId: 'environment-4',
        timestamp: DateTime.utc(2026, 8, 19),
        environment: environment,
      );
      const diagnostics = PeerDiagnostics(
        peerId: 'peer-a',
        state: PeerState.online,
        e2eePolicy: E2eePolicy.required,
        readyPathCount: 1,
      );

      expect(event.environment.generation, 4);
      expect(event.lane, NetworkEventLane.control);
      expect(diagnostics.readyPathCount, 1);
      expect(diagnostics.e2eePolicy, E2eePolicy.required);
    },
  );

  test('V2 request identities are independently bounded', () {
    expect(
      () => SendMessageRequest(
        peerId: 'peer-a',
        messageId: 'm' * (NetworkV2Limits.maxMessageIdBytes + 1),
        payload: Uint8List(0),
      ),
      throwsArgumentError,
    );
    expect(
      () => OpenStreamRequest(
        peerId: 'peer-a',
        openerDeviceId: 'device-a',
        streamId: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => TransferFileRequest(
        peerId: 'peer-a',
        transferId: '',
        filePath: '/tmp/file',
      ),
      throwsArgumentError,
    );
  });

  test('tracker rejects mismatched peer terminal results', () async {
    final tracker = CommandResultTracker();
    final completer = tracker.register<void>(
      commandId: 'command-peer',
      peerId: 'peer-a',
    );
    expect(
      tracker.complete(
        CommandResult<void>.success(
          commandId: 'command-peer',
          peerId: 'peer-b',
        ),
      ),
      isFalse,
    );
    expect(tracker.pendingCount, 1);
    expect(tracker.cancel('command-peer'), isTrue);
    expect((await completer.future).isCancelled, isTrue);
  });

  test('public error precedence never lets NoRoute hide security', () {
    const security = NetworkError(
      code: NetworkErrorCode.securityPolicyMismatch,
      message: 'policy mismatch',
    );
    const noRoute = NetworkError(
      code: NetworkErrorCode.noRoute,
      message: 'no route',
    );
    expect(
      resolvePublicNetworkError(configOrSecurity: security, noRoute: noRoute),
      same(security),
    );
  });

  test(
    'domain ports route V2 commands and facade disposal keeps owner resources',
    () async {
      final port = _RecordingNetworkV2CommandPort();
      final facade = NetworkV2FacadeImpl(port);

      await facade.start();
      await facade.connectPeer(ConnectPeerRequest(peerId: 'peer-a'));
      await facade.disconnectPeer(DisconnectPeerRequest(peerId: 'peer-a'));
      await facade.removePeer(RemovePeerRequest(peerId: 'peer-a'));
      await facade.peerDiagnostics(PeerDiagnosticsRequest(peerId: 'peer-a'));
      await facade.transferFile(
        TransferFileRequest(
          peerId: 'peer-a',
          transferId: 'transfer-a',
          filePath: '/tmp/file',
        ),
      );
      await facade.sendMessage(
        SendMessageRequest(
          peerId: 'peer-a',
          messageId: 'message-a',
          payload: Uint8List.fromList(<int>[1]),
        ),
      );
      await facade.openStream(
        OpenStreamRequest(
          peerId: 'peer-a',
          openerDeviceId: 'device-a',
          streamId: 1,
        ),
      );

      expect(
        port.requests.map((request) => request.runtimeType),
        containsAll(<Type>[
          ConnectPeerRequest,
          DisconnectPeerRequest,
          RemovePeerRequest,
          TransferFileRequest,
          SendMessageRequest,
          OpenStreamRequest,
        ]),
      );
      await facade.dispose();

      expect(facade.lifecycle, NetworkV2LifecycleState.disposed);
      expect(port.stopCalls, 0);
      expect(port.disposeCalls, 0);
    },
  );
}

final class _RecordingNetworkV2CommandPort implements NetworkV2CommandPort {
  final List<PeerScopedRequest> requests = <PeerScopedRequest>[];
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<NetworkV2Event> get events => const Stream<NetworkV2Event>.empty();

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<CommandResult<T>> execute<T>(PeerScopedRequest request) async {
    requests.add(request);
    return CommandResult<T>.success(
      commandId: 'command-${requests.length}',
      peerId: request.peerId,
    );
  }

  @override
  Future<CommandResult<PeerDiagnostics>> diagnostics(String peerId) async =>
      CommandResult<PeerDiagnostics>.success(
        commandId: 'diagnostics',
        peerId: peerId,
        value: PeerDiagnostics(
          peerId: peerId,
          state: PeerState.online,
          e2eePolicy: E2eePolicy.required,
        ),
      );

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
