// NetworkTelemetryBridge direct-failure, fallback, and ordering tests.

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/telemetry/network_telemetry_bridge.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'telemetry_test_utils.dart';

void main() {
  group('NetworkTelemetryBridge fallback records', () {
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
      'maps direct failure through relay fallback to connected on one trace',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-operation');
        events.add(
          RouteAttemptChanged(
            eventId: 'e1',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            attemptId: 'attempt-a',
            phase: RouteAttemptPhase.directFailed,
            routeType: NetworkRouteType.quicDirect,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'direct handshake refused',
            ),
          ),
        );
        await _settle();

        events.add(
          RouteAttemptChanged(
            eventId: 'e1b',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            attemptId: 'attempt-a',
            phase: RouteAttemptPhase.relayFallbackStarted,
            routeType: NetworkRouteType.relay,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'direct handshake refused',
            ),
          ),
        );
        await _settle();
        events.add(
          RouteChanged(
            eventId: 'e2',
            timestamp: DateTime.now(),
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-a',
              routeType: NetworkRouteType.relay,
            ),
          ),
        );
        await _settle();

        events.add(
          PeerStateChanged(
            eventId: 'e3',
            timestamp: DateTime.now(),
            peerId: 'peer-a',
            state: PeerConnectionState.connected,
            routeType: NetworkRouteType.relay,
          ),
        );
        await _settle();

        final records = await harness.replayRecords();
        expect(
          records.map((record) => record.eventName),
          containsAllInOrder([
            TelemetryEvents.networkQuicFailed.name,
            TelemetryEvents.networkRelayFallback.name,
            TelemetryEvents.networkRelayConnected.name,
          ]),
        );
        expect(records.map((record) => record.traceId).toSet(), {
          'trace-operation',
        });
      },
    );

    test(
      'persists SSH and network lifecycle events in one trace order',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-operation');
        unawaited(
          harness.client.record(
            event: TelemetryEvents.sshSessionStarted,
            traceId: 'trace-operation',
            properties: {'session_type': 'terminal'},
          ),
        );
        await _settle();

        events.add(
          RouteAttemptChanged(
            eventId: 'e1',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            attemptId: 'attempt-a',
            phase: RouteAttemptPhase.directFailed,
            routeType: NetworkRouteType.quicDirect,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'direct handshake refused',
            ),
          ),
        );
        await _settle();
        events.add(
          RouteAttemptChanged(
            eventId: 'e1b',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            attemptId: 'attempt-a',
            phase: RouteAttemptPhase.relayFallbackStarted,
            routeType: NetworkRouteType.relay,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'direct handshake refused',
            ),
          ),
        );
        await _settle();
        events.add(
          RouteChanged(
            eventId: 'e2',
            timestamp: DateTime.now(),
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-a',
              routeType: NetworkRouteType.relay,
            ),
          ),
        );
        await _settle();
        events.add(
          PeerStateChanged(
            eventId: 'e3',
            timestamp: DateTime.now(),
            peerId: 'peer-a',
            state: PeerConnectionState.connected,
            routeType: NetworkRouteType.relay,
          ),
        );
        await _settle();
        await harness.client.record(
          event: TelemetryEvents.sshSessionConnected,
          traceId: 'trace-operation',
          properties: {'session_type': 'terminal'},
        );

        final records = await harness.replayRecords();
        expect(records.map((record) => record.eventName), [
          TelemetryEvents.sshSessionStarted.name,
          TelemetryEvents.networkQuicFailed.name,
          TelemetryEvents.networkRelayFallback.name,
          TelemetryEvents.networkRelayConnected.name,
          TelemetryEvents.sshSessionConnected.name,
        ]);
        expect(records.map((record) => record.traceId).toSet(), {
          'trace-operation',
        });
      },
    );

    test(
      'terminal direct failure records QUIC only, with fallback false',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-direct');
        events.add(
          PeerStateChanged(
            eventId: 'failed',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            state: PeerConnectionState.failed,
            routeType: NetworkRouteType.quicDirect,
            routeTransport: NetworkRouteTransport.quic,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'direct only failed',
            ),
          ),
        );
        await _settle();

        final records = await harness.recordsByName();
        final quic = records[TelemetryEvents.networkQuicFailed.name]!;
        expect(quic, hasLength(1));
        expect(quic.single.properties, containsPair('fallback_used', false));
        expect(records[TelemetryEvents.networkRelayFallback.name], isNull);
      },
    );

    test(
      'classifies an unverified QUIC failure with the generic error code',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-generic');
        events.add(
          PeerStateChanged(
            eventId: 'failed',
            timestamp: now,
            peerId: 'peer-a',
            state: PeerConnectionState.failed,
            routeType: NetworkRouteType.quicDirect,
            routeTransport: NetworkRouteTransport.quic,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'QUIC connection failed during handshake',
            ),
          ),
        );
        await _settle();

        final records = await harness.recordsByName();
        final quic = records[TelemetryEvents.networkQuicFailed.name]!;
        expect(quic, hasLength(1));
        expect(
          quic.single.error?.errorCode,
          TelemetryErrorCodes.netQuicFailed.code,
        );
      },
    );

    test(
      'causal direct failure survives an unspecified terminal peer state',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-direct');
        events.add(
          RouteAttemptChanged(
            eventId: 'direct-attempt',
            timestamp: now,
            peerId: 'peer-a',
            attemptId: 'attempt-direct',
            phase: RouteAttemptPhase.directFailed,
            routeType: NetworkRouteType.quicDirect,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'direct route refused',
            ),
          ),
        );
        events.add(
          PeerStateChanged(
            eventId: 'terminal',
            timestamp: now,
            peerId: 'peer-a',
            state: PeerConnectionState.failed,
            routeType: NetworkRouteType.unspecified,
            error: const NetworkError(
              code: NetworkErrorCode.noRoute,
              message: 'no eligible fallback route',
            ),
          ),
        );
        await _settle();

        final records = await harness.recordsByName();
        final quic = records[TelemetryEvents.networkQuicFailed.name]!;
        expect(quic, hasLength(1));
        expect(
          quic.single.error?.errorCode,
          TelemetryErrorCodes.netQuicConnRefused.code,
        );
        expect(quic.single.error?.message, 'direct route refused');
        expect(quic.single.properties, containsPair('fallback_used', false));
        expect(records[TelemetryEvents.networkRelayFallback.name], isNull);
      },
    );

    test(
      'route RTT is recorded once from RouteChanged, never as zero',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-rtt');
        events.add(
          PeerStateChanged(
            eventId: 'connected',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            state: PeerConnectionState.connected,
            routeType: NetworkRouteType.quicDirect,
          ),
        );
        events.add(
          RouteChanged(
            eventId: 'route',
            timestamp: DateTime.utc(2026, 1, 1),
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-a',
              routeType: NetworkRouteType.quicDirect,
              rtt: Duration(milliseconds: 37),
            ),
          ),
        );
        await _settle();

        final records = (await harness
            .recordsByName())[TelemetryEvents.networkQuicConnected.name]!;
        expect(records, hasLength(1));
        expect(records.single.properties, containsPair('rtt_ms', 37));
        expect(records.single.properties, isNot(containsPair('rtt_ms', 0)));
      },
    );
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
