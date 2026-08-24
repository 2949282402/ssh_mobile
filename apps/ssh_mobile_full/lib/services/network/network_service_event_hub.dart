part of 'network_service.dart';

/// 公开事件的唯一发布点；订阅者不拥有 native subscription。
final class _NetworkEventHub {
  final StreamController<NetworkEvent> _controller =
      StreamController<NetworkEvent>.broadcast();

  Stream<NetworkEvent> get stream => _controller.stream;

  void add(NetworkEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
