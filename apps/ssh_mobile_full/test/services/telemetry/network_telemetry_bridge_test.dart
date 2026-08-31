// Network route and Relay telemetry bridge route-recording tests.

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/telemetry/network_telemetry_bridge.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'telemetry_test_utils.dart';

void main() {
  group('NetworkTelemetryBridge route records', () {
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

    test('route evaluated as quicDirect records quic connected', () async {
      traces.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
      events.add(
        RouteChanged(
          eventId: 'e1',
          timestamp: DateTime.now(),
          snapshot: const SdkRouteSnapshot(
            peerId: 'peer-a',
            routeType: NetworkRouteType.quicDirect,
            rtt: Duration(milliseconds: 42),
          ),
        ),
      );
      await _settle();

      final records = await harness.recordsByName();
      final quic = records[TelemetryEvents.networkQuicConnected.name];

      expect(quic, hasLength(1));
      expect(quic!.single.properties, containsPair('rtt_ms', 42));
      expect(quic.single.properties, containsPair('protocol_version', 'v2'));
    });

    test(
      'bounds quic deduplication and re-records an expired trace once',
      () async {
        const churnCount = 257;
        final start = now;

        for (var index = 0; index < churnCount; index++) {
          now = start.add(Duration(milliseconds: index));
          final peerId = 'peer-$index';
          final traceId = 'trace-$index';
          traces.bindPeer(peerId: peerId, traceId: traceId);
          events.add(
            RouteChanged(
              eventId: 'churn-$index',
              timestamp: now,
              snapshot: SdkRouteSnapshot(
                peerId: peerId,
                routeType: NetworkRouteType.quicDirect,
              ),
            ),
          );
          await _settle();
        }

        var records = (await harness
            .recordsByName())[TelemetryEvents.networkQuicConnected.name]!;
        expect(records, hasLength(churnCount));

        // The oldest entry is evicted after the 257th successful operation,
        // while the newest entry remains deduplicated at the same instant.
        now = start.add(const Duration(milliseconds: churnCount));
        traces.bindPeer(peerId: 'peer-0', traceId: 'trace-0');
        events.add(
          RouteChanged(
            eventId: 'evicted',
            timestamp: now,
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-0',
              routeType: NetworkRouteType.quicDirect,
            ),
          ),
        );
        await _settle();
        records = (await harness
            .recordsByName())[TelemetryEvents.networkQuicConnected.name]!;
        expect(records, hasLength(churnCount + 1));

        traces.bindPeer(peerId: 'peer-256', traceId: 'trace-256');
        events.add(
          RouteChanged(
            eventId: 'duplicate',
            timestamp: now,
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-256',
              routeType: NetworkRouteType.quicDirect,
            ),
          ),
        );
        await _settle();
        records = (await harness
            .recordsByName())[TelemetryEvents.networkQuicConnected.name]!;
        expect(records, hasLength(churnCount + 1));

        now = now.add(traces.bindingTtl + const Duration(milliseconds: 1));
        traces.bindPeer(peerId: 'peer-256', traceId: 'trace-256');
        events.add(
          RouteChanged(
            eventId: 'expired',
            timestamp: now,
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-256',
              routeType: NetworkRouteType.quicDirect,
            ),
          ),
        );
        await _settle();
        records = (await harness
            .recordsByName())[TelemetryEvents.networkQuicConnected.name]!;
        expect(records, hasLength(churnCount + 2));
        expect(
          records.where((record) => record.traceId == 'trace-0'),
          hasLength(2),
        );
        expect(
          records.where((record) => record.traceId == 'trace-256'),
          hasLength(2),
        );
      },
    );

    test(
      'route evaluated as relay records relay connected with shared trace',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
        events.add(
          RouteChanged(
            eventId: 'e1',
            timestamp: DateTime.now(),
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-a',
              routeType: NetworkRouteType.relay,
            ),
          ),
        );
        await _settle();
        events.add(
          RelayStateChanged(
            eventId: 'e2',
            timestamp: DateTime.now(),
            state: RelayConnectionState.connected,
          ),
        );
        await _settle();

        final records = await harness.recordsByName();
        final relay = records[TelemetryEvents.networkRelayConnected.name];

        expect(relay, hasLength(1));
        expect(
          relay!.map((r) => r.traceId).toSet(),
          hasLength(1),
          reason: 'evaluated 与 connected 事件应共享 traceId',
        );
        for (final record in relay) {
          expect(record.properties, containsPair('relay_region', 'unknown'));
        }
      },
    );

    test(
      'relay failure records a relay failure and fallback diagnostic',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
        events.add(
          RouteAttemptChanged(
            eventId: 'attempt-1',
            timestamp: DateTime.utc(2026, 1, 1),
            peerId: 'peer-a',
            attemptId: 'attempt-a',
            phase: RouteAttemptPhase.relayFallbackStarted,
            routeType: NetworkRouteType.relay,
            error: const NetworkError(
              code: NetworkErrorCode.quicError,
              message: 'No route to relay',
            ),
          ),
        );
        events.add(
          RelayStateChanged(
            eventId: 'e1',
            timestamp: DateTime.now(),
            state: RelayConnectionState.connecting,
          ),
        );
        events.add(
          RelayStateChanged(
            eventId: 'e2',
            timestamp: DateTime.now(),
            state: RelayConnectionState.failed,
            error: const NetworkError(
              code: NetworkErrorCode.noRoute,
              message: 'No route to relay',
            ),
          ),
        );
        await _settle();

        final records = await harness.recordsByName();
        final relayFailed = records[TelemetryEvents.networkRelayFailed.name];
        final relayFallback =
            records[TelemetryEvents.networkRelayFallback.name];

        expect(relayFailed, hasLength(1));
        expect(relayFallback, hasLength(1));

        final relayFailedRecord = relayFailed!.single;
        expect(
          relayFailedRecord.error?.errorCode,
          TelemetryErrorCodes.netRelayUnavailable.code,
        );
        expect(
          relayFailedRecord.properties,
          containsPair('reason', 'No route to relay'),
        );
        expect(
          relayFailedRecord.properties,
          containsPair('fallback_used', true),
        );

        final fallbackRecord = relayFallback!.single;
        expect(
          fallbackRecord.error?.errorCode,
          TelemetryErrorCodes.netRelayUnavailable.code,
        );
        expect(
          fallbackRecord.properties,
          containsPair('direct_error', 'No route to relay'),
        );
        expect(fallbackRecord.traceId, relayFailedRecord.traceId);
      },
    );

    test(
      'an unrelated Relay control reconnect is not an SSH fallback',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
        events.add(
          RelayStateChanged(
            eventId: 'relay-connecting',
            timestamp: now,
            state: RelayConnectionState.connecting,
          ),
        );
        events.add(
          RelayStateChanged(
            eventId: 'relay-failed',
            timestamp: now,
            state: RelayConnectionState.failed,
            error: const NetworkError(
              code: NetworkErrorCode.relayError,
              message: 'control reconnect failed',
            ),
          ),
        );
        await _settle();

        expect(await harness.replayRecords(), isEmpty);
      },
    );

    test(
      'disconnect clears the span so a later connect starts a new trace',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
        events.add(
          RouteChanged(
            eventId: 'e1',
            timestamp: DateTime.now(),
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-a',
              routeType: NetworkRouteType.quicDirect,
            ),
          ),
        );
        await _settle();
        events.add(
          PeerStateChanged(
            eventId: 'e2',
            timestamp: DateTime.now(),
            peerId: 'peer-a',
            state: PeerConnectionState.disconnected,
            routeType: NetworkRouteType.quicDirect,
          ),
        );
        await _settle();
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-b');
        events.add(
          RouteChanged(
            eventId: 'e3',
            timestamp: DateTime.now(),
            snapshot: const SdkRouteSnapshot(
              peerId: 'peer-a',
              routeType: NetworkRouteType.quicDirect,
            ),
          ),
        );
        await _settle();

        final quic = (await harness
            .recordsByName())[TelemetryEvents.networkQuicConnected.name];
        expect(quic, hasLength(2));
        expect(
          quic!.map((r) => r.traceId).toSet(),
          hasLength(2),
          reason: 'disconnect 后应开启新的 trace span',
        );
      },
    );
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
