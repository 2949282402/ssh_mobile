import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/lan_share_feature_adapters.dart';

void main() {
  test(
    'LAN network factory borrows one App-owned facade for every generation',
    () async {
      final runtime = _CountingRuntime();
      final facade = _RecordingFacade();
      final factory = AppLanShareNetworkFactory(runtime, facade);

      final first = await factory.create(
        deviceId: 'device-a',
        identityPrivateKey: Uint8List(32),
        e2ePrivateKey: Uint8List(32),
        listenAddress: '0.0.0.0:0',
        receiveDirectory: '/tmp/network-receive',
      );
      final second = await factory.create(
        deviceId: 'device-a',
        identityPrivateKey: Uint8List(32),
        e2ePrivateKey: Uint8List(32),
        listenAddress: '0.0.0.0:0',
        receiveDirectory: '/tmp/network-receive',
      );

      expect(first, same(facade));
      expect(second, same(facade));
      expect(runtime.ensureCapabilityCalls, 0);
      expect(runtime.openCommandGatewayCalls, 0);
      expect(facade.startCalls, 0);
      expect(facade.disposeCalls, 0);
    },
  );
}

final class _CountingRuntime implements NetworkRuntime {
  int ensureCapabilityCalls = 0;
  int openCommandGatewayCalls = 0;

  @override
  NetworkRuntimeState get state => NetworkRuntimeState.ready;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const <NetworkCapability>[],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {
    ensureCapabilityCalls++;
  }

  @override
  Future<NetworkCommandGateway> openCommandGateway() async {
    openCommandGatewayCalls++;
    throw StateError('factory must not open a second command gateway');
  }

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async =>
      throw StateError('not used');

  @override
  bool isCapabilityReady(NetworkCapability capability) => true;

  @override
  Future<void> dispose() async {}
}

final class _RecordingFacade extends Fake implements NetworkFacade {
  int startCalls = 0;
  int disposeCalls = 0;

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async {
    startCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
