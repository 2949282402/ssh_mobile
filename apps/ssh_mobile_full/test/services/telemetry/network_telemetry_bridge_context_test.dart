// NetworkTelemetryBridge context correlation, deduplication, and disposal tests.

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/telemetry/network_telemetry_bridge.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'telemetry_test_utils.dart';

void main() {
  group('NetworkTelemetryBridge contexts', () {
    late TelemetryTestHarness harness;
    late StreamController<SdkEvent> events;
    late NetworkTelemetryBridge bridge;
    late TelemetryTraceRegistry traces;
    late DateTime now;

    setUp(() {
      harness = TelemetryTestHarness();
      events = StreamController<SdkEvent>.broadcast();
      traces = TelemetryTraceRegistry();
      now = DateTime.utc(2026, 1, 1);
      bridge = NetworkTelemetryBridge(
        telemetryClient: harness.client,
        events: events.stream,
        traceRegistry: traces,
        clock: () => now,
      );
      bridge.attach();
    });

    tearDown(() async {
      await bridge.dispose();
      traces.dispose();
      await events.close();
      await harness.dispose();
    });

    test(
      'command-correlated route attempts isolate same-peer traces',
      () async {
        traces
          ..bindPeer(peerId: 'peer-a', traceId: 'trace-a')
          ..bindCommand(
            commandId: 'command-a',
            peerId: 'peer-a',
            traceId: 'trace-a',
          )
          ..bindPeer(peerId: 'peer-a', traceId: 'trace-b')
          ..bindCommand(
            commandId: 'command-b',
            peerId: 'peer-a',
            traceId: 'trace-b',
          );
        events.add(
          RouteAttemptChanged(
            eventId: 'a-direct',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            attemptId: 'attempt-a',
            commandId: 'command-a',
            phase: RouteAttemptPhase.directFailed,
            routeType: NetworkRouteType.quicDirect,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'a refused',
            ),
          ),
        );
        events.add(
          RouteAttemptChanged(
            eventId: 'a-fallback',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            attemptId: 'attempt-a',
            commandId: 'command-a',
            phase: RouteAttemptPhase.relayFallbackStarted,
            routeType: NetworkRouteType.relay,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'a refused',
            ),
          ),
        );
        await _settle();

        final records = await harness.replayRecords();
        expect(records, isNotEmpty);
        expect(records.map((record) => record.traceId).toSet(), {'trace-a'});
      },
    );

    test(
      'late route attempt cannot move an old same-peer result to a new trace',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-old');
        events.add(
          RouteAttemptChanged(
            eventId: 'old-direct',
            timestamp: now,
            peerId: 'peer-a',
            attemptId: 'attempt-old',
            phase: RouteAttemptPhase.directFailed,
            routeType: NetworkRouteType.quicDirect,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'old direct failure',
            ),
          ),
        );
        events.add(
          PeerStateChanged(
            eventId: 'old-terminal',
            timestamp: now,
            peerId: 'peer-a',
            state: PeerConnectionState.failed,
            routeType: NetworkRouteType.quicDirect,
            routeTransport: NetworkRouteTransport.quic,
          ),
        );
        await _settle();

        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-new');
        events.add(
          RouteAttemptChanged(
            eventId: 'late-old-fallback',
            timestamp: now,
            peerId: 'peer-a',
            attemptId: 'attempt-old',
            phase: RouteAttemptPhase.relayFallbackStarted,
            routeType: NetworkRouteType.relay,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'late old fallback',
            ),
          ),
        );
        await _settle();

        final records = await harness.replayRecords();
        expect(
          records.where((record) => record.traceId == 'trace-new'),
          isEmpty,
        );
        expect(
          records.where((record) => record.traceId == 'trace-old'),
          hasLength(1),
        );
      },
    );

    test(
      'ambiguous command correlation fails closed instead of using peer trace',
      () async {
        traces
          ..bindPeer(peerId: 'peer-a', traceId: 'trace-a')
          ..bindPeer(peerId: 'peer-a', traceId: 'trace-b')
          ..bindCommand(
            commandId: 'command-collision',
            peerId: 'peer-a',
            traceId: 'trace-a',
          )
          ..bindCommand(
            commandId: 'command-collision',
            peerId: 'peer-a',
            traceId: 'trace-b',
          );
        events.add(
          RouteAttemptChanged(
            eventId: 'ambiguous',
            timestamp: now,
            peerId: 'peer-a',
            attemptId: 'attempt-collision',
            commandId: 'command-collision',
            phase: RouteAttemptPhase.directFailed,
            routeType: NetworkRouteType.quicDirect,
          ),
        );
        await _settle();

        expect(await harness.replayRecords(), isEmpty);
      },
    );

    test('expired bridge context cannot reuse a released trace', () async {
      traces.bindPeer(peerId: 'peer-a', traceId: 'trace-expiring');
      events.add(
        RouteChanged(
          eventId: 'lan',
          timestamp: DateTime.utc(2026, 1, 1),
          snapshot: const SdkRouteSnapshot(
            peerId: 'peer-a',
            routeType: NetworkRouteType.lan,
          ),
        ),
      );
      await _settle();
      traces.releasePeerTrace(peerId: 'peer-a', traceId: 'trace-expiring');
      now = now.add(const Duration(minutes: 5));
      events.add(
        RouteChanged(
          eventId: 'late',
          timestamp: DateTime.utc(2026, 1, 1, 0, 5),
          snapshot: const SdkRouteSnapshot(
            peerId: 'peer-a',
            routeType: NetworkRouteType.quicDirect,
            rtt: Duration(milliseconds: 20),
          ),
        ),
      );
      await _settle();

      expect(
        (await harness
            .recordsByName())[TelemetryEvents.networkQuicConnected.name],
        isNull,
      );
    });

    test(
      'does not create an independent network trace without an operation',
      () async {
        events.add(
          RouteChanged(
            eventId: 'e1',
            timestamp: DateTime.now(),
            snapshot: const SdkRouteSnapshot(
              peerId: 'unbound-peer',
              routeType: NetworkRouteType.quicDirect,
            ),
          ),
        );
        events.add(
          RelayStateChanged(
            eventId: 'e2',
            timestamp: DateTime.now(),
            state: RelayConnectionState.connected,
          ),
        );
        await _settle();

        expect(await harness.replayRecords(), isEmpty);
      },
    );

    test(
      'registry keeps same-peer collisions ambiguous and releases exactly',
      () {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
        traces.bindCommand(
          commandId: 'command-a',
          peerId: 'peer-a',
          traceId: 'trace-a',
        );
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-b');
        traces.bindCommand(
          commandId: 'command-a',
          peerId: 'peer-a',
          traceId: 'trace-b',
        );

        expect(
          traces.traceForPeer('peer-a'),
          isNull,
          reason:
              'peer-only events cannot identify either concurrent operation',
        );
        expect(
          traces.traceForCommand('command-a'),
          isNull,
          reason: 'a late result must not be attributed to the newer trace',
        );

        traces.completeCommand('command-a');
        expect(traces.traceForCommand('command-a'), isNull);
        expect(
          traces.traceForPeer('peer-a'),
          isNull,
          reason: 'ambiguous peer contexts remain until each operation retires',
        );
        traces.releasePeerTrace(peerId: 'peer-a', traceId: 'trace-b');
        expect(traces.traceForPeer('peer-a'), 'trace-a');
        traces.releasePeerTrace(peerId: 'peer-a', traceId: 'trace-a');
        expect(traces.traceForPeer('peer-a'), isNull);
      },
    );

    test('registry evicts stale contexts within the configured bound', () {
      var registryNow = DateTime.utc(2026, 1, 1);
      final bounded = TelemetryTraceRegistry(
        bindingTtl: const Duration(seconds: 10),
        maxBindings: 2,
        clock: () => registryNow,
      );
      bounded.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
      registryNow = registryNow.add(const Duration(seconds: 1));
      bounded.bindPeer(peerId: 'peer-b', traceId: 'trace-b');
      registryNow = registryNow.add(const Duration(seconds: 1));
      bounded.bindCommand(
        commandId: 'command-c',
        peerId: 'peer-c',
        traceId: 'trace-c',
      );
      expect(bounded.peerBindingCount + bounded.commandBindingCount, 2);
      expect(bounded.traceForPeer('peer-a'), isNull);
      // Expiration at the exact TTL cutoff is inclusive: a context touched at
      // t=2 must not survive when the cutoff reaches t=2.
      registryNow = registryNow.add(const Duration(seconds: 10));
      expect(bounded.peerBindingCount, 0);
      expect(bounded.commandBindingCount, 0);
      bounded.dispose();
    });

    test('bridge disposal does not release a borrower-owned trace', () async {
      traces.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
      await bridge.dispose();
      expect(traces.traceForPeer('peer-a'), 'trace-a');
    });
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
