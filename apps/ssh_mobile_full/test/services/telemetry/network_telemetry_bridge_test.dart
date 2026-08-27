// 网络路由与回退生命周期遥测桥测试。
//
// 直接向 NetworkTelemetryBridge 注入 typed SdkEvent 流，验证：
// - RouteChanged(quicDirect) -> network.quic.connected；
// - RouteChanged(relay) -> network.relay.connected；
// - RelayStateChanged(failed) -> network.relay.failed + network.relay.fallback；
// - 同一 peer 的事件共享 traceId。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/telemetry/network_telemetry_bridge.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'telemetry_test_utils.dart';

void main() {
  group('NetworkTelemetryBridge', () {
    late TelemetryTestHarness harness;
    late StreamController<SdkEvent> events;
    late NetworkTelemetryBridge bridge;
    late TelemetryTraceRegistry traces;

    setUp(() {
      harness = TelemetryTestHarness();
      events = StreamController<SdkEvent>.broadcast();
      traces = TelemetryTraceRegistry();
      bridge = NetworkTelemetryBridge(
        telemetryClient: harness.client,
        events: events.stream,
        traceRegistry: traces,
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

    test(
      'maps direct failure through relay fallback to connected on one trace',
      () async {
        traces.bindPeer(peerId: 'peer-a', traceId: 'trace-operation');
        events.add(
          PeerStateChanged(
            eventId: 'e1',
            timestamp: DateTime.now(),
            peerId: 'peer-a',
            state: PeerConnectionState.failed,
            routeType: NetworkRouteType.quicDirect,
            routeTransport: NetworkRouteTransport.quic,
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
          PeerStateChanged(
            eventId: 'e1',
            timestamp: DateTime.now(),
            peerId: 'peer-a',
            state: PeerConnectionState.failed,
            routeType: NetworkRouteType.quicDirect,
            routeTransport: NetworkRouteTransport.quic,
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
        expect(
          records.map((record) => record.eventName),
          [
            TelemetryEvents.sshSessionStarted.name,
            TelemetryEvents.networkQuicFailed.name,
            TelemetryEvents.networkRelayFallback.name,
            TelemetryEvents.networkRelayConnected.name,
            TelemetryEvents.sshSessionConnected.name,
          ],
        );
        expect(records.map((record) => record.traceId).toSet(), {
          'trace-operation',
        });
      },
    );

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
      var now = DateTime.utc(2026, 1, 1);
      final bounded = TelemetryTraceRegistry(
        bindingTtl: const Duration(seconds: 10),
        maxBindings: 2,
        clock: () => now,
      );
      bounded.bindPeer(peerId: 'peer-a', traceId: 'trace-a');
      now = now.add(const Duration(seconds: 1));
      bounded.bindPeer(peerId: 'peer-b', traceId: 'trace-b');
      now = now.add(const Duration(seconds: 1));
      bounded.bindCommand(
        commandId: 'command-c',
        peerId: 'peer-c',
        traceId: 'trace-c',
      );
      expect(bounded.peerBindingCount + bounded.commandBindingCount, 2);
      expect(bounded.traceForPeer('peer-a'), isNull);
      now = now.add(const Duration(seconds: 20));
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
