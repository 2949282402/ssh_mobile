// 网络路由与回退生命周期遥测桥。
//
// 订阅 network_sdk 的 typed 事件流，把路由评估/回退观察映射为生成 contract
// 中已注册的网络遥测事件。状态上下文、事件路由、去重和记录分别由相邻 part
// 文件维护，保持 bridge 的生命周期和 trace 关联边界集中在此处。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:network_sdk/network_sdk.dart';

import 'telemetry_span.dart';

part 'network_telemetry_bridge_contexts.dart';
part 'network_telemetry_bridge_routes.dart';
part 'network_telemetry_bridge_records.dart';
part 'network_telemetry_bridge_models.dart';

/// 监听 [NetworkFacade.events] 并把网络路由生命周期投影为遥测事件。
///
/// 生命周期与 facade 对齐：由 Composition Root 在 telemetryClient 创建后构造，
/// 并调用 [attach]/[dispose] 与 facade 或 runtime 同步释放。所有 span 事件共享
/// SSH connect operation 的 traceId，保证 evaluated -> connected/fallback 端到端
/// 关联。Bridge 不拥有 trace registry，只借用并在释放时清除自己的观察状态。
final class NetworkTelemetryBridge {
  NetworkTelemetryBridge({
    required this.telemetryClient,
    required this._events,
    required this.traceRegistry,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const int _maxPeerContexts = 256;

  final TelemetryClient telemetryClient;
  final Stream<SdkEvent> _events;
  final TelemetryTraceRegistry traceRegistry;
  final DateTime Function() _clock;
  StreamSubscription<SdkEvent>? _subscription;
  bool _disposed = false;

  /// Trace context copied from the registry for late route events that do not
  /// carry a command id. A local context is used only after the registry has
  /// released the same operation; a newer registry binding always wins, and
  /// an ambiguous same-peer binding is ignored.
  final Map<String, _BridgePeerContext> _peerContexts =
      <String, _BridgePeerContext>{};
  final Map<String, _PendingDirectFailure> _pendingDirectFailures =
      <String, _PendingDirectFailure>{};
  final Map<String, _BridgeAttemptContext> _attemptContexts =
      <String, _BridgeAttemptContext>{};
  final Map<String, String> _recordedDirectFailures = <String, String>{};
  String? _relayTraceId;
  String? _relayPeerId;
  final Map<String, DateTime> _quicConnectedTraces = <String, DateTime>{};
  final Map<String, DateTime> _relayConnectedTraces = <String, DateTime>{};

  /// Records are serialized at the bridge boundary so event callbacks cannot
  /// reorder network spans. TelemetryClient also serializes all producers,
  /// which keeps SSH.started ahead of a native event even when both callers
  /// use fire-and-forget recording.
  Future<void> _recordQueue = Future<void>.value();

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

  void _handleEvent(SdkEvent event) => _handleNetworkEvent(this, event);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    // The registry belongs to AppRuntime/connector. The bridge only drains
    // writes and drops its own copied contexts; it must not release a trace
    // still needed by another borrower.
    await _recordQueue;
    _peerContexts.clear();
    _pendingDirectFailures.clear();
    _attemptContexts.clear();
    _recordedDirectFailures.clear();
    _relayTraceId = null;
    _relayPeerId = null;
    _quicConnectedTraces.clear();
    _relayConnectedTraces.clear();
  }
}
