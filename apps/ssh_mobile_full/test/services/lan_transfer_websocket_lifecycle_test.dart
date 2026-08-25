// LAN Control V2 WebSocket 生命周期和类型化连接事件测试。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';

class _ControllableWebSocket extends Fake implements WebSocket {
  _ControllableWebSocket({this.closeGate});

  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final Completer<void>? closeGate;
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
    await closeGate?.future;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}

class _BlockingCredentialSecurityService extends LanSecurityService {
  _BlockingCredentialSecurityService(this.credentialGate)
    : super(appOwnedX25519PrivateSeed: Uint8List(32));

  final Completer<String?> credentialGate;

  @override
  Future<String?> getOutboundAccessToken(String deviceId) =>
      credentialGate.future;
}

/// 执行类型化 LAN WebSocket 生命周期测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a replaced socket cannot disconnect the current socket', () async {
    final service = LanTransferService(
      currentDeviceId: 'local-device',
      securityService: LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
      ),
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
      await service.close();
    }
  });

  test('close waits for sockets before closing event streams', () async {
    final closeGate = Completer<void>();
    final service = LanTransferService(
      currentDeviceId: 'local-device',
      securityService: LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
      ),
      storageService: LanStorageService(),
    );
    final socket = _ControllableWebSocket(closeGate: closeGate);
    final streamClosed = Completer<void>();
    final subscription = service.connectionStateStream.listen(
      (_) {},
      onDone: streamClosed.complete,
    );
    service.registerActiveWebSocketForTesting('peer-device', socket);

    var closeCompleted = false;
    final closing = service.close().whenComplete(() => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(socket.closeCalls, 1);
    expect(closeCompleted, isFalse);
    expect(streamClosed.isCompleted, isFalse);

    closeGate.complete();
    await closing;
    expect(streamClosed.isCompleted, isTrue);
    expect(service.isWebSocketConnected('peer-device'), isFalse);
    await subscription.cancel();
  });

  test('close waits for an in-flight outbound connection attempt', () async {
    final credentialGate = Completer<String?>();
    final service = LanTransferService(
      currentDeviceId: 'local-device',
      securityService: _BlockingCredentialSecurityService(credentialGate),
      storageService: LanStorageService(),
    );
    final device = LanDiscoveredPeer(
      deviceId: 'peer-device',
      alias: 'Peer',
      ip: '192.0.2.10',
      controlPort: 53317,
      advertisedNativePort: null,
      deviceType: LanDeviceType.desktop,
      os: 'linux',
      lastSeen: DateTime.now(),
    );

    final connecting = service.connectWebSocket(device);
    var closeCompleted = false;
    final closing = service.close().whenComplete(() => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(closeCompleted, isFalse);
    credentialGate.complete(null);
    expect(await connecting, isA<NetworkFailure<void>>());
    await closing;
    expect(closeCompleted, isTrue);
  });
}
