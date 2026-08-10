import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:feature_lan_share/feature_lan_share.dart';

class _RecordingLanDiscoveryService extends LanDiscoveryService {
  final List<int> startedPorts = [];
  int stopCount = 0;

  _RecordingLanDiscoveryService()
    : super(
        currentDeviceId: 'local-device',
        currentDeviceAlias: 'Original alias',
      );

  @override
  Future<void> performStartAdvertising(int port) async {
    startedPorts.add(port);
  }

  @override
  Future<void> performStopAdvertising() async {
    stopCount++;
  }
}

class _RecordingMulticastLock implements LanMulticastLock {
  bool isHeld = false;
  int acquireCount = 0;
  int releaseCount = 0;

  @override
  Future<void> acquire() async {
    if (isHeld) return;
    isHeld = true;
    acquireCount++;
  }

  @override
  Future<void> release() async {
    if (!isHeld) return;
    isHeld = false;
    releaseCount++;
  }
}

class _ControllableLanDiscoveryService extends LanDiscoveryService {
  final List<Completer<nsd.Discovery>> pendingStarts = [];
  final List<String> stoppedDiscoveryIds = [];

  _ControllableLanDiscoveryService({required LanMulticastLock multicastLock})
    : super(
        currentDeviceId: 'local-device',
        currentDeviceAlias: 'Local device',
        multicastLock: multicastLock,
      );

  @override
  Future<nsd.Discovery> performStartDiscovery() {
    final completer = Completer<nsd.Discovery>();
    pendingStarts.add(completer);
    return completer.future;
  }

  @override
  Future<void> performStopDiscovery(nsd.Discovery discovery) async {
    stoppedDiscoveryIds.add(discovery.id);
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for the discovery lifecycle state.');
}

void main() {
  test(
    'alias re-registration preserves the active native HTTPS port',
    () async {
      final discovery = _RecordingLanDiscoveryService();

      await discovery.startAdvertising(port: 61443);
      await discovery.updateDeviceAlias('Renamed device');

      expect(discovery.currentDeviceAlias, 'Renamed device');
      expect(discovery.startedPorts, [61443, 61443]);
      expect(discovery.stopCount, 1);
      expect(discovery.advertisedPort, 61443);

      discovery.dispose();
    },
  );

  test('UDP PING advertises the native HTTPS port', () {
    final payload = LanDiscoveryService.createUdpPingPayload(
      deviceId: 'local-device',
      alias: 'Desktop',
      os: 'windows',
      port: 62001,
    );

    expect(payload, {
      'type': 'PING',
      'id': 'local-device',
      'alias': 'Desktop',
      'port': 62001,
      'os': 'windows',
    });
  });

  test('stale devices expire while recently seen devices remain', () {
    final discovery = _RecordingLanDiscoveryService();
    final now = DateTime(2026, 7, 18, 12);
    discovery.registerManualDevice(
      LanDevice(
        id: 'stale-peer',
        alias: 'Stale',
        ip: '192.168.1.10',
        port: 53317,
        deviceType: LanDeviceType.desktop,
        osName: 'windows',
        lastSeen: now.subtract(const Duration(seconds: 91)),
      ),
    );
    discovery.registerManualDevice(
      LanDevice(
        id: 'fresh-peer',
        alias: 'Fresh',
        ip: '192.168.1.11',
        port: 53317,
        deviceType: LanDeviceType.mobile,
        osName: 'android',
        lastSeen: now.subtract(const Duration(seconds: 5)),
      ),
    );

    expect(discovery.removeStaleDevices(now: now), 1);
    expect(discovery.currentDiscoveredDevices.map((device) => device.id), [
      'fresh-peer',
    ]);

    discovery.dispose();
  });

  test(
    'start-stop-start cleans a stale session without releasing the new lock',
    () async {
      final multicastLock = _RecordingMulticastLock();
      final discovery = _ControllableLanDiscoveryService(
        multicastLock: multicastLock,
      );

      final firstStart = discovery.startDiscovery();
      await _waitUntil(() => discovery.pendingStarts.length == 1);

      final stop = discovery.stopDiscovery();
      final restart = discovery.startDiscovery();
      discovery.pendingStarts.first.complete(nsd.Discovery('stale-session'));

      await _waitUntil(() => discovery.pendingStarts.length == 2);

      expect(discovery.stoppedDiscoveryIds, ['stale-session']);
      expect(multicastLock.acquireCount, 2);
      expect(multicastLock.releaseCount, 1);
      expect(multicastLock.isHeld, isTrue);

      discovery.pendingStarts.last.complete(nsd.Discovery('active-session'));
      await Future.wait([firstStart, stop, restart]);

      expect(discovery.isScanning, isTrue);
      expect(discovery.stoppedDiscoveryIds, ['stale-session']);
      expect(multicastLock.isHeld, isTrue);

      await discovery.stopDiscovery();

      expect(discovery.stoppedDiscoveryIds, [
        'stale-session',
        'active-session',
      ]);
      expect(multicastLock.acquireCount, 2);
      expect(multicastLock.releaseCount, 2);
      expect(multicastLock.isHeld, isFalse);

      discovery.dispose();
    },
  );
}
