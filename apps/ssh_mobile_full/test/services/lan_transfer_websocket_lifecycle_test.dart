// v1 LAN WebSocket 生命周期和类型化连接事件测试。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_network_models.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';

class _ControllableWebSocket extends Fake implements WebSocket {
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  int closeCalls = 0;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  Duration? _pingInterval;
  @override
  set pingInterval(Duration? value) {
    _pingInterval = value;
  }

  @override
  Duration? get pingInterval => _pingInterval;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closeCalls++;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}

/// 执行类型化 LAN WebSocket 生命周期测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a replaced socket cannot disconnect the current socket', () async {
    final service = LanTransferService(
      currentDeviceId: 'local-device',
      securityService: LanSecurityService(),
      storageService: LanStorageService(),
    );
    final states = <LanConnectionStateChanged>[];
    final subscription = service.connectionStateStream.listen(states.add);
    final oldSocket = _ControllableWebSocket();
    final currentSocket = _ControllableWebSocket();

    try {
      service.registerActiveWebSocketForTesting('peer-device', oldSocket);
      service.registerActiveWebSocketForTesting('peer-device', currentSocket);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(oldSocket.closeCalls, greaterThanOrEqualTo(1));
      expect(currentSocket.closeCalls, 0);
      expect(service.isWebSocketConnected('peer-device'), isTrue);
      expect(
        states.where(
          (state) => state.deviceId == 'peer-device' && !state.connected,
        ),
        isEmpty,
      );

      await currentSocket.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.isWebSocketConnected('peer-device'), isFalse);
      expect(states.last.deviceId, 'peer-device');
      expect(states.last.connected, isFalse);
    } finally {
      await subscription.cancel();
      await service.closeConnections();
      service.dispose();
    }
  });
}
