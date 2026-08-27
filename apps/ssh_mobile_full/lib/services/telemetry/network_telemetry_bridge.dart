// 网络路由与回退生命周期遥测桥。
//
// 订阅 network_sdk 的 typed 事件流，把路由评估/回退观察映射为生成 contract
// 中已注册的网络遥测事件。直接连接与 Relay 失败分别使用对应的 typed
// TelemetryEvents 定义，避免业务代码复制 wire event names。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:network_sdk/network_sdk.dart';

import 'telemetry_span.dart';

/// 监听 [NetworkFacade.events] 并把网络路由生命周期投影为遥测事件。
///
/// 生命周期与 facade 对齐：由 Composition Root 在 telemetryClient 创建后构造，
/// 并调用 [attach]/[dispose] 与 facade 或 runtime 同步释放。所有 span 事件共享
/// 同一个 traceId，保证 evaluated -> connected/fallback 端到端关联。
final class NetworkTelemetryBridge {
  NetworkTelemetryBridge({
    required this.telemetryClient,
    required this._events,
  });

  final TelemetryClient telemetryClient;
  final Stream<SdkEvent> _events;
  StreamSubscription<SdkEvent>? _subscription;
  bool _disposed = false;

  /// 每个对端最近一次路由评估的 traceId 与开始时间。
  final Map<String, String> _traceIds = {};
  final Map<String, DateTime> _startedAt = {};

  /// 开始订阅事件流。
  void attach() {
    if (_disposed || _subscription != null) return;
    _subscription = _events.listen(
      _handleEvent,
      onError: (_) {
        // 事件流错误不终止遥测；保留 bag-of-events 槽位给后续 fallback 记录。
      },
    );
  }

  void _handleEvent(SdkEvent event) {
    if (event case PeerStateChanged(
      :final peerId,
      :final state,
      :final routeType,
    )) {
      if (state == PeerConnectionState.connected) {
        _recordRouteConnected(peerId, routeType);
      } else if (state == PeerConnectionState.failed ||
          state == PeerConnectionState.disconnected) {
        _traceIds.remove(peerId);
        _startedAt.remove(peerId);
      }
    } else if (event case RouteChanged(:final snapshot)) {
      _recordRouteEvaluated(snapshot);
    } else if (event case RelayStateChanged(:final state, :final error)) {
      if (state == RelayConnectionState.connected) {
        final traceId = _traceIds.putIfAbsent('relay', () {
          return _newSpan('relay');
        });
        unawaited(
          telemetryClient.record(
            event: TelemetryEvents.networkRelayConnected,
            traceId: traceId,
            properties: {'relay_region': _relayRegion()},
          ),
        );
      } else if (state == RelayConnectionState.failed) {
        final traceId = _traceIds.remove('relay');
        _startedAt.remove('relay');
        final reason = error?.message ?? 'relay_failed';
        final fallbackUsed =
            error?.code == NetworkErrorCode.noRoute ||
            error?.code == NetworkErrorCode.relayError;
        unawaited(
          telemetryClient.record(
            event: TelemetryEvents.networkRelayFailed,
            traceId: traceId,
            errorCode: TelemetryErrorCodes.netRelayUnavailable,
            errorMessage: reason,
            properties: {'reason': reason, 'fallback_used': fallbackUsed},
          ),
        );
        // 回退已触发：记录 relay fallback 诊断事件。
        unawaited(
          telemetryClient.record(
            event: TelemetryEvents.networkRelayFallback,
            traceId: traceId,
            errorCode: TelemetryErrorCodes.netRelayUnavailable,
            errorMessage: reason,
            properties: {'direct_error': reason},
          ),
        );
      } else if (state == RelayConnectionState.connecting) {
        _traceIds.putIfAbsent('relay', () => _newSpan('relay'));
      }
    }
  }

  /// RouteChanged 表示路由评估完成，投影为 quic/relay connected 事件。
  void _recordRouteEvaluated(SdkRouteSnapshot snapshot) {
    final peerId = snapshot.peerId;
    final traceId = _traceIds.putIfAbsent(peerId, () => _newSpan(peerId));
    final rttMs = snapshot.rtt?.inMilliseconds ?? 0;

    switch (snapshot.routeType) {
      case NetworkRouteType.quicDirect:
        unawaited(
          telemetryClient.record(
            event: TelemetryEvents.networkQuicConnected,
            traceId: traceId,
            properties: {'rtt_ms': rttMs, 'protocol_version': 'v2'},
          ),
        );
      case NetworkRouteType.relay:
        final relayTraceId = _traceIds.putIfAbsent(
          'relay',
          () => _newSpan('relay'),
        );
        unawaited(
          telemetryClient.record(
            event: TelemetryEvents.networkRelayConnected,
            traceId: relayTraceId,
            properties: {'relay_region': _relayRegion()},
          ),
        );
      case NetworkRouteType.lan:
      // LAN 直连不单独上报；保留 trace span 供后续失败事件关联。
      case NetworkRouteType.unspecified:
        // 路由未评估完成，不产生可聚合的事件。
        break;
    }
  }

  void _recordRouteConnected(String peerId, NetworkRouteType routeType) {
    final traceId = _traceIds.putIfAbsent(peerId, () => _newSpan(peerId));
    switch (routeType) {
      case NetworkRouteType.quicDirect:
        unawaited(
          telemetryClient.record(
            event: TelemetryEvents.networkQuicConnected,
            traceId: traceId,
            properties: {'rtt_ms': 0, 'protocol_version': 'v2'},
          ),
        );
      case NetworkRouteType.relay:
        final relayTraceId = _traceIds.putIfAbsent(
          'relay',
          () => _newSpan('relay'),
        );
        unawaited(
          telemetryClient.record(
            event: TelemetryEvents.networkRelayConnected,
            traceId: relayTraceId,
            properties: {'relay_region': _relayRegion()},
          ),
        );
      case NetworkRouteType.lan:
      case NetworkRouteType.unspecified:
        break;
    }
  }

  String _newSpan(String key) {
    _startedAt[key] = DateTime.now();
    return newTelemetryTraceId();
  }

  /// 当前 Relay region 仅作为占位值；正式 region 由 relay 配置/Handshake
  /// 返回后写入，避免把端点 URL 泄漏到遥测。
  String _relayRegion() => 'unknown';

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    _traceIds.clear();
    _startedAt.clear();
  }
}
