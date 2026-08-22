part of 'network_service.dart';

/// Native frame 路由端口：把命令结果交给 coordinator，把业务事件交给
/// projection 与公开 event hub。
final class _NetworkEventRouter {
  _NetworkEventRouter({
    required NetworkCommandGateway gateway,
    required this.commands,
    required this.projection,
    required this.eventHub,
  }) {
    _nativeSubscription = gateway.events.listen(_handleNativeEvent);
  }

  final _NetworkCommandCoordinator commands;
  final _NetworkStateProjection projection;
  final _NetworkEventHub eventHub;
  late final StreamSubscription<Uint8List> _nativeSubscription;

  void _handleNativeEvent(Uint8List bytes) {
    try {
      final frame = commands.handleNativeFrame(bytes);
      if (frame == null) return;
      final event = frame.event;
      if (event == null) return;
      final update = projection.apply(event);
      eventHub.add(event);
      for (final peerId in update.invalidatedRelayPeers) {
        eventHub.add(
          PeerStateChanged(
            eventId:
                '$peerId/relay-disconnected/${event.timestamp.millisecondsSinceEpoch}',
            timestamp: event.timestamp,
            peerId: peerId,
            state: PeerConnectionState.disconnected,
            routeType: NetworkRouteType.unspecified,
            error: update.relayError,
          ),
        );
      }
    } on FormatException {
      // 格式错误的原生帧在事件边界被忽略。待完成调用只能由原生命令结果完成。
    }
  }

  Future<void> close() => _nativeSubscription.cancel();
}
