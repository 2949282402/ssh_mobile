import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  group('NetworkV2FacadeImpl lifecycle', () {
    test('start and stop are idempotent and can be restarted', () async {
      final port = _FakeNetworkV2CommandPort();
      final facade = NetworkV2FacadeImpl(port);

      expect(facade.lifecycle, NetworkV2LifecycleState.created);
      await facade.start();
      expect(facade.lifecycle, NetworkV2LifecycleState.running);
      await facade.start();
      expect(port.startCalls, 1);

      await facade.stop();
      expect(facade.lifecycle, NetworkV2LifecycleState.stopped);
      await facade.stop();
      expect(port.stopCalls, 1);

      await facade.start();
      expect(facade.lifecycle, NetworkV2LifecycleState.running);
      expect(port.startCalls, 2);
    });

    test('stop from created does not stop the owner port', () async {
      final port = _FakeNetworkV2CommandPort();
      final facade = NetworkV2FacadeImpl(port);

      await facade.stop();

      expect(facade.lifecycle, NetworkV2LifecycleState.stopped);
      expect(port.stopCalls, 0);
    });

    test('start failure leaves the facade retryable', () async {
      final port = _FakeNetworkV2CommandPort()
        ..startError = StateError('start failed');
      final facade = NetworkV2FacadeImpl(port);

      await expectLater(facade.start(), throwsStateError);
      expect(facade.lifecycle, NetworkV2LifecycleState.created);

      port.startError = null;
      await facade.start();
      expect(facade.lifecycle, NetworkV2LifecycleState.running);
      expect(port.startCalls, 2);
    });

    test('stop failure still publishes the stopped lifecycle state', () async {
      final port = _FakeNetworkV2CommandPort()
        ..stopError = StateError('stop failed');
      final facade = NetworkV2FacadeImpl(port);
      await facade.start();

      await expectLater(facade.stop(), throwsStateError);
      expect(facade.lifecycle, NetworkV2LifecycleState.stopped);
    });

    test('start rejects while an asynchronous stop is in progress', () async {
      final port = _FakeNetworkV2CommandPort();
      final facade = NetworkV2FacadeImpl(port);
      await facade.start();
      final stopGate = Completer<void>();
      port.stopGate = stopGate;

      final stopFuture = facade.stop();
      await Future<void>.delayed(Duration.zero);
      expect(facade.lifecycle, NetworkV2LifecycleState.stopping);
      await expectLater(facade.start(), throwsStateError);

      stopGate.complete();
      await stopFuture;
      expect(facade.lifecycle, NetworkV2LifecycleState.stopped);
    });

    test(
      'a second stop while stopping does not call the owner twice',
      () async {
        final port = _FakeNetworkV2CommandPort();
        final facade = NetworkV2FacadeImpl(port);
        await facade.start();
        final stopGate = Completer<void>();
        port.stopGate = stopGate;

        final firstStop = facade.stop();
        await Future<void>.delayed(Duration.zero);
        final secondStop = facade.stop();
        await secondStop;
        expect(port.stopCalls, 1);

        stopGate.complete();
        await firstStop;
      },
    );

    test(
      'commands require running state and reject stopped/disposed state',
      () async {
        final port = _FakeNetworkV2CommandPort();
        final facade = NetworkV2FacadeImpl(port);
        final request = ConnectPeerRequest(peerId: 'peer-a');

        expect(() => facade.connectPeer(request), throwsStateError);
        await facade.start();
        await facade.stop();
        expect(() => facade.connectPeer(request), throwsStateError);

        await facade.dispose();
        expect(
          () => facade.connectPeer(request),
          throwsA(isA<SdkClientDisposedException>()),
        );
        await expectLater(
          facade.start(),
          throwsA(isA<SdkClientDisposedException>()),
        );
      },
    );

    test(
      'dispose is idempotent and never disposes the injected owner port',
      () async {
        final port = _FakeNetworkV2CommandPort();
        final facade = NetworkV2FacadeImpl(port);
        await facade.start();

        await facade.dispose();
        await facade.dispose();

        expect(facade.lifecycle, NetworkV2LifecycleState.disposed);
        expect(port.stopCalls, 0);
        expect(port.disposeCalls, 0);
      },
    );
  });

  group('NetworkV2FacadeImpl domain routing', () {
    test('routes every domain operation to the matching request', () async {
      final port = _FakeNetworkV2CommandPort();
      final facade = NetworkV2FacadeImpl(port);
      await facade.start();

      final connect = ConnectPeerRequest(peerId: 'peer-a');
      final disconnect = DisconnectPeerRequest(peerId: 'peer-a');
      final remove = RemovePeerRequest(peerId: 'peer-a');
      final diagnostics = PeerDiagnosticsRequest(peerId: 'peer-a');
      final transfer = TransferFileRequest(
        peerId: 'peer-a',
        transferId: 'transfer-a',
        filePath: '/tmp/file',
      );
      final message = SendMessageRequest(
        peerId: 'peer-a',
        messageId: 'message-a',
        payload: Uint8List.fromList(<int>[1, 2]),
      );
      final stream = OpenStreamRequest(
        peerId: 'peer-a',
        openerDeviceId: 'device-a',
        streamId: 7,
      );

      await facade.connectPeer(connect);
      await facade.disconnectPeer(disconnect);
      await facade.removePeer(remove);
      final diagnosticsResult = await facade.peerDiagnostics(diagnostics);
      await facade.transferFile(transfer);
      await facade.sendMessage(message);
      await facade.openStream(stream);

      expect(port.requests, <PeerScopedRequest>[
        connect,
        disconnect,
        remove,
        transfer,
        message,
        stream,
      ]);
      expect(diagnosticsResult.value?.peerId, 'peer-a');
    });

    test(
      'forwards command failures without translating the typed error',
      () async {
        final port = _FakeNetworkV2CommandPort()
          ..executeResult = (request) => CommandResult<void>.failure(
            commandId: 'failed-command',
            peerId: request.peerId,
            error: const NetworkError(
              code: NetworkErrorCode.pathLost,
              message: 'carrier closed',
            ),
          );
        final facade = NetworkV2FacadeImpl(port);
        await facade.start();

        final result = await facade.connectPeer(
          ConnectPeerRequest(peerId: 'peer-a'),
        );

        expect(result.state, CommandTerminalState.failed);
        expect(result.error?.code, NetworkErrorCode.pathLost);
        expect(result.peerId, 'peer-a');
      },
    );

    test('events are exposed as the exact owner stream', () async {
      final port = _FakeNetworkV2CommandPort();
      final facade = NetworkV2FacadeImpl(port);
      final event = PeerStateChangedEvent(
        eventId: 'event-a',
        timestamp: DateTime.utc(2026, 8, 21),
        peerId: 'peer-a',
        state: PeerState.online,
      );

      final received = facade.events.first;
      port.eventsController.add(event);

      expect(await received, same(event));
    });
  });

  group('NetworkV2CommandTracker boundaries', () {
    test('rejects non-positive capacity and duplicate registrations', () async {
      expect(
        () => CommandResultTracker(maxPendingCommands: 0),
        throwsA(isA<AssertionError>()),
      );
      final tracker = CommandResultTracker(maxPendingCommands: 1);
      final completer = tracker.register<void>(commandId: 'command-a');

      expect(
        () => tracker.register<void>(commandId: 'command-a'),
        throwsStateError,
      );
      expect(
        () => tracker.register<void>(commandId: 'command-b'),
        throwsStateError,
      );
      expect(tracker.cancel('command-a'), isTrue);
      expect((await completer.future).isCancelled, isTrue);
      expect(tracker.register<void>(commandId: 'command-b'), isNotNull);
    });

    test(
      'handles unknown, mismatched, correct, and duplicate results',
      () async {
        final tracker = CommandResultTracker();
        final completer = tracker.register<void>(
          commandId: 'command-a',
          peerId: 'peer-a',
        );
        final success = CommandResult<void>.success(
          commandId: 'command-a',
          peerId: 'peer-a',
        );

        expect(
          tracker.complete(CommandResult<void>.success(commandId: 'unknown')),
          isFalse,
        );
        expect(
          tracker.complete(
            CommandResult<void>.success(
              commandId: 'command-a',
              peerId: 'peer-b',
            ),
          ),
          isFalse,
        );
        expect(tracker.pendingCount, 1);
        expect(tracker.complete(success), isTrue);
        expect(tracker.complete(success), isFalse);
        expect((await completer.future).isSuccess, isTrue);
        expect(tracker.pendingCount, 0);
      },
    );

    test(
      'cancel returns explicit errors and unknown cancellation is harmless',
      () async {
        final tracker = CommandResultTracker();
        final completer = tracker.register<void>(commandId: 'command-a');
        const error = NetworkError(
          code: NetworkErrorCode.timeout,
          message: 'deadline',
        );

        expect(tracker.cancel('unknown'), isFalse);
        expect(tracker.cancel('command-a', error: error), isTrue);
        final result = await completer.future;
        expect(result.state, CommandTerminalState.cancelled);
        expect(result.error, same(error));
      },
    );

    test('cancelAll completes each pending command once', () async {
      final tracker = CommandResultTracker();
      final first = tracker.register<void>(commandId: 'command-a');
      final second = tracker.register<void>(commandId: 'command-b');
      const error = NetworkError(
        code: NetworkErrorCode.cancelled,
        message: 'runtime stopped',
      );

      tracker.cancelAll(error: error);

      expect(tracker.pendingCount, 0);
      expect((await first.future).error, same(error));
      expect((await second.future).error, same(error));
      expect(tracker.cancel('command-a'), isFalse);
    });

    test('completer rejects a result for another command', () async {
      final completer = CommandResultCompleter<void>(commandId: 'command-a');

      expect(
        completer.complete(CommandResult<void>.success(commandId: 'command-b')),
        isFalse,
      );
      expect(completer.isCompleted, isFalse);
      expect(
        completer.complete(CommandResult<void>.success(commandId: 'command-a')),
        isTrue,
      );
      expect(completer.isCompleted, isTrue);
      expect((await completer.future).isSuccess, isTrue);
      expect(
        completer.complete(CommandResult<void>.success(commandId: 'command-a')),
        isFalse,
      );
    });
  });

  group('Network V2 value boundaries', () {
    test('copies payloads and accepts exact custom limits only', () {
      final source = Uint8List.fromList(<int>[1, 2, 3]);
      final payload = NetworkPayload(source, maxBytes: 3);
      source[0] = 9;
      final returned = payload.bytes;
      returned[1] = 8;

      expect(payload.bytes, orderedEquals(<int>[1, 2, 3]));
      expect(payload.length, 3);
      expect(
        () => NetworkPayload(Uint8List(4), maxBytes: 3),
        throwsArgumentError,
      );
      expect(
        () => NetworkPayload(Uint8List(0), maxBytes: -1),
        throwsArgumentError,
      );
    });

    test('peer and command identifiers enforce UTF-8 byte limits', () {
      final exactPeer = _repeat('é', NetworkV2Limits.maxPeerIdBytes ~/ 2);
      final oversizedPeer = '$exactPeeré';
      expect(ConnectPeerRequest(peerId: exactPeer).peerId, exactPeer);
      expect(
        () => ConnectPeerRequest(peerId: oversizedPeer),
        throwsArgumentError,
      );

      final exactCommand = _repeat('é', NetworkV2Limits.maxCommandIdBytes ~/ 2);
      expect(
        CommandResult<void>.success(commandId: exactCommand).commandId,
        exactCommand,
      );
      expect(
        () => CommandResult<void>.success(commandId: '$exactCommandé'),
        throwsArgumentError,
      );
    });

    test(
      'request identity limits include stream endpoints and UTF-8 paths',
      () {
        expect(() => DisconnectPeerRequest(peerId: ''), throwsArgumentError);
        expect(
          () => TransferFileRequest(
            peerId: 'peer-a',
            transferId: '',
            filePath: '/tmp/file',
          ),
          throwsArgumentError,
        );
        expect(
          () => TransferFileRequest(
            peerId: 'peer-a',
            transferId: 'transfer-a',
            filePath: _oversizedUtf8(NetworkV2Limits.maxFilePathBytes),
          ),
          throwsArgumentError,
        );
        expect(
          OpenStreamRequest(
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 1,
          ).streamId,
          1,
        );
        expect(
          OpenStreamRequest(
            peerId: 'peer-a',
            openerDeviceId: 'device-a',
            streamId: 0xffff,
          ).streamId,
          0xffff,
        );
        for (final invalidId in <int>[0, 0x10000]) {
          expect(
            () => OpenStreamRequest(
              peerId: 'peer-a',
              openerDeviceId: 'device-a',
              streamId: invalidId,
            ),
            throwsArgumentError,
          );
        }
      },
    );

    test('diagnostic/environment limits fail closed in assertions', () {
      expect(
        () => NetworkEnvironment(
          generation: -1,
          hasConnectivity: true,
          isForeground: true,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PeerDiagnostics(
          peerId: 'peer-a',
          state: PeerState.online,
          e2eePolicy: E2eePolicy.required,
          readyPathCount: NetworkV2Limits.maxPeerCounters + 1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('Network V2 events and error precedence', () {
    test(
      'typed events preserve lane, priority, peer, and bounded payloads',
      () {
        final timestamp = DateTime.utc(2026, 8, 21);
        final command = CommandResult<void>.success(
          commandId: 'command-a',
          peerId: 'peer-a',
        );
        final commandEvent = CommandResultEvent<void>(
          eventId: 'event-command',
          timestamp: timestamp,
          result: command,
        );
        final stateEvent = PeerStateChangedEvent(
          eventId: 'event-state',
          timestamp: timestamp,
          peerId: 'peer-a',
          state: PeerState.online,
          e2eePolicy: E2eePolicy.required,
        );
        final diagnosticsEvent = PeerDiagnosticsChangedEvent(
          eventId: 'event-diagnostics',
          timestamp: timestamp,
          diagnostics: const PeerDiagnostics(
            peerId: 'peer-a',
            state: PeerState.online,
            e2eePolicy: E2eePolicy.required,
          ),
        );
        final messageEvent = PeerMessageEvent(
          eventId: 'event-message',
          timestamp: timestamp,
          peerId: 'peer-a',
          messageId: 'message-a',
          payload: Uint8List.fromList(<int>[1]),
        );
        final transferEvent = PeerTransferProgressEvent(
          eventId: 'event-transfer',
          timestamp: timestamp,
          peerId: 'peer-a',
          transferId: 'transfer-a',
          bytesTransferred: 2,
          totalBytes: 4,
        );
        final streamEvent = PeerStreamDataEvent(
          eventId: 'event-stream',
          timestamp: timestamp,
          peerId: 'peer-a',
          openerDeviceId: 'device-a',
          streamId: 1,
          data: Uint8List.fromList(<int>[3]),
        );

        expect(commandEvent.lane, NetworkEventLane.control);
        expect(commandEvent.priority, NetworkEventPriority.criticalControl);
        expect(commandEvent.peerId, 'peer-a');
        expect(stateEvent.priority, NetworkEventPriority.criticalControl);
        expect(diagnosticsEvent.priority, NetworkEventPriority.normalControl);
        expect(messageEvent.lane, NetworkEventLane.data);
        expect(messageEvent.payload.bytes, orderedEquals(<int>[1]));
        expect(transferEvent.lane, NetworkEventLane.data);
        expect(streamEvent.data.length, 1);
      },
    );

    test('stream payload accepts the exact limit and rejects overflow', () {
      expect(
        PeerStreamDataEvent(
          eventId: 'event-stream',
          timestamp: DateTime.utc(2026, 8, 21),
          peerId: 'peer-a',
          openerDeviceId: 'device-a',
          streamId: 1,
          data: Uint8List(NetworkV2Limits.maxStreamChunkBytes),
        ).data.length,
        NetworkV2Limits.maxStreamChunkBytes,
      );
      expect(
        () => PeerStreamDataEvent(
          eventId: 'event-stream',
          timestamp: DateTime.utc(2026, 8, 21),
          peerId: 'peer-a',
          openerDeviceId: 'device-a',
          streamId: 1,
          data: Uint8List(NetworkV2Limits.maxStreamChunkBytes + 1),
        ),
        throwsArgumentError,
      );
    });

    test('public error precedence is stable at every fallback level', () {
      const config = NetworkError(
        code: NetworkErrorCode.configuration,
        message: 'config',
      );
      const peer = NetworkError(
        code: NetworkErrorCode.peerOffline,
        message: 'peer',
      );
      const resource = NetworkError(
        code: NetworkErrorCode.resourceLimit,
        message: 'resource',
      );
      const timeout = NetworkError(
        code: NetworkErrorCode.timeout,
        message: 'timeout',
      );
      const noRoute = NetworkError(
        code: NetworkErrorCode.noRoute,
        message: 'route',
      );

      expect(
        resolvePublicNetworkError(
          configOrSecurity: config,
          peerStatus: peer,
          resourceOrLifecycle: resource,
          timeout: timeout,
          noRoute: noRoute,
        ),
        same(config),
      );
      expect(
        resolvePublicNetworkError(
          peerStatus: peer,
          resourceOrLifecycle: resource,
          timeout: timeout,
          noRoute: noRoute,
        ),
        same(peer),
      );
      expect(
        resolvePublicNetworkError(
          resourceOrLifecycle: resource,
          timeout: timeout,
          noRoute: noRoute,
        ),
        same(resource),
      );
      expect(
        resolvePublicNetworkError(timeout: timeout, noRoute: noRoute),
        same(timeout),
      );
      expect(resolvePublicNetworkError(noRoute: noRoute), same(noRoute));
      expect(resolvePublicNetworkError(), isNull);
    });
  });
}

String _repeat(String value, int count) =>
    List<String>.filled(count, value).join();

String _oversizedUtf8(int maxBytes) => _repeat('é', maxBytes ~/ 2 + 1);

final class _FakeNetworkV2CommandPort implements NetworkV2CommandPort {
  final StreamController<NetworkV2Event> eventsController =
      StreamController<NetworkV2Event>.broadcast();
  final List<PeerScopedRequest> requests = <PeerScopedRequest>[];
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  Object? startError;
  Object? stopError;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  CommandResult<void> Function(PeerScopedRequest request)? executeResult;

  @override
  Stream<NetworkV2Event> get events => eventsController.stream;

  @override
  Future<void> start() async {
    startCalls++;
    final gate = startGate;
    if (gate != null) await gate.future;
    final error = startError;
    if (error != null) throw error;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final gate = stopGate;
    if (gate != null) await gate.future;
    final error = stopError;
    if (error != null) throw error;
  }

  @override
  Future<CommandResult<T>> execute<T>(PeerScopedRequest request) async {
    requests.add(request);
    final result = executeResult?.call(request);
    if (result != null) return result as CommandResult<T>;
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
