import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}
