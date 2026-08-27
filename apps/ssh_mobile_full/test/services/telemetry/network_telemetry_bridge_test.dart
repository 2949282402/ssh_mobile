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
            error: NetworkError(
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
            error: NetworkError(
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
            error: NetworkError(
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
            error: NetworkError(
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
            snapshot: SdkRouteSnapshot(
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
            error: NetworkError(
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
            error: NetworkError(
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
          snapshot: SdkRouteSnapshot(
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
          snapshot: SdkRouteSnapshot(
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
      // Expiration at the exact TTL cutoff is inclusive: a context touched at
      // t=2 must not survive when the cutoff reaches t=2.
      now = now.add(const Duration(seconds: 10));
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
