// 网络路由与回退生命周期遥测桥测试。
//
// 直接向 NetworkTelemetryBridge 注入 typed SdkEvent 流，验证：
// - RouteChanged(quicDirect) -> network.quic.connected；
// - RouteChanged(relay) -> network.relay.connected；
// - RelayStateChanged(failed) -> network.quic.failed + network.relay.fallback；
// - 同一 peer 的事件共享 traceId。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/telemetry/app_telemetry_contract.dart';
import 'package:ssh_mobile/services/telemetry/network_telemetry_bridge.dart';

import 'telemetry_test_utils.dart';

void main() {
  group('NetworkTelemetryBridge', () {
    late TelemetryTestHarness harness;
    late StreamController<SdkEvent> events;
    late NetworkTelemetryBridge bridge;

    setUp(() {
      harness = TelemetryTestHarness();
      events = StreamController<SdkEvent>.broadcast();
      bridge = NetworkTelemetryBridge(
        telemetryClient: harness.client,
        events: events.stream,
      );
      bridge.attach();
    });

    tearDown(() async {
      await bridge.dispose();
      await events.close();
      await harness.dispose();
    });

    test('route evaluated as quicDirect records quic connected', () async {
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
      final quic = records[AppTelemetryEvents.networkQuicConnected.name];

      expect(quic, hasLength(1));
      expect(quic!.single.properties, containsPair('rtt_ms', 42));
      expect(quic.single.properties, containsPair('protocol_version', 'v2'));
    });

    test('route evaluated as relay records relay connected with shared trace',
        () async {
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
      events.add(
        RelayStateChanged(
          eventId: 'e2',
          timestamp: DateTime.now(),
          state: RelayConnectionState.connected,
        ),
      );
      await _settle();

      final records = await harness.recordsByName();
      final relay = records[AppTelemetryEvents.networkRelayConnected.name];

      expect(relay, hasLength(2));
      expect(
        relay!.map((r) => r.traceId).toSet(),
        hasLength(1),
        reason: 'evaluated 与 connected 事件应共享 traceId',
      );
      for (final record in relay) {
        expect(record.properties, containsPair('relay_region', 'unknown'));
      }
    });

    test('relay failure records quic failed with fallback diagnostic',
        () async {
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
      final quicFailed = records[AppTelemetryEvents.networkQuicFailed.name];
      final relayFallback =
          records[AppTelemetryEvents.networkRelayFallback.name];

      expect(quicFailed, hasLength(1));
      expect(relayFallback, hasLength(1));

      final quicFailedRecord = quicFailed!.single;
      expect(
        quicFailedRecord.error?.errorCode,
        AppTelemetryErrorCodes.netRelayUnavailable.code,
      );
      expect(quicFailedRecord.properties, containsPair('reason', 'No route to relay'));
      expect(quicFailedRecord.properties, containsPair('fallback_used', true));

      final fallbackRecord = relayFallback!.single;
      expect(fallbackRecord.error?.errorCode,
          AppTelemetryErrorCodes.netRelayUnavailable.code);
      expect(fallbackRecord.properties, containsPair('direct_error', 'No route to relay'));
      expect(fallbackRecord.traceId, quicFailedRecord.traceId);
    });

    test('disconnect clears the span so a later connect starts a new trace',
        () async {
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
      events.add(
        PeerStateChanged(
          eventId: 'e2',
          timestamp: DateTime.now(),
          peerId: 'peer-a',
          state: PeerConnectionState.disconnected,
          routeType: NetworkRouteType.quicDirect,
        ),
      );
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

      final quic =
          (await harness.recordsByName())[AppTelemetryEvents.networkQuicConnected.name];
      expect(quic, hasLength(2));
      expect(quic!.map((r) => r.traceId).toSet(), hasLength(2),
          reason: 'disconnect 后应开启新的 trace span');
    });
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);