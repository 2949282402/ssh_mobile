import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:ssh_mobile/services/background_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBackgroundPlatform background;
  late _FakePermissionPlatform permission;
  final powerChannel = const MethodChannel('ssh_mobile/power');
  final powerCalls = <String>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    background = _FakeBackgroundPlatform();
    permission = _FakePermissionPlatform(PermissionStatus.denied);
    FlutterBackgroundServicePlatform.instance = background;
    PermissionHandlerPlatform.instance = permission;
    powerCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(powerChannel, (call) async {
          powerCalls.add(call.method);
          if (background.throwOnPowerCall) {
            throw StateError('power channel failed');
          }
          return call.method == 'isIgnoringBatteryOptimizations' ? false : true;
        });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(powerChannel, null);
    await background.dispose();
  });

  test('configures, starts, reports, and stops the mobile service', () async {
    // A failed prewarm is reported but leaves the manager retryable.
    background.throwOnConfigure = true;
    await BackgroundServiceManager.prewarm();
    expect(background.configureCalls, 1);
    background.throwOnConfigure = false;
    await BackgroundServiceManager.initialize();
    expect(permission.requested, 1);
    expect(background.configureCalls, 2);

    // Repeated prewarm is idempotent after the platform has been configured.
    await BackgroundServiceManager.prewarm();
    expect(background.configureCalls, 2);

    await BackgroundServiceManager.start(
      connectionName: 'demo',
      showConnectionName: true,
    );
    expect(background.running, isTrue);
    expect(background.invocations, contains('update'));
    expect(background.lastArguments['content'], 'Connected to demo');

    BackgroundServiceManager.updateStatus('custom status');
    expect(background.lastArguments['content'], 'custom status');

    expect(
      await BackgroundServiceManager.isIgnoringBatteryOptimizations(),
      isFalse,
    );
    await BackgroundServiceManager.requestBatteryOptimizationExemption();
    await BackgroundServiceManager.openAppSettings();
    await Future<void>.delayed(Duration.zero);
    expect(
      powerCalls,
      containsAll(<String>[
        'isIgnoringBatteryOptimizations',
        'requestBatteryOptimizationExemption',
        'openAppSettings',
      ]),
    );

    await BackgroundServiceManager.stop();
    expect(background.running, isFalse);
    expect(background.invocations, contains('stopService'));
  });

  test(
    'prewarm swallows configuration failures and unsupported platforms no-op',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await BackgroundServiceManager.initialize();
      await BackgroundServiceManager.start();
      await BackgroundServiceManager.stop();
      BackgroundServiceManager.updateStatus('ignored');
      expect(background.invocations, isEmpty);
      expect(
        await BackgroundServiceManager.isIgnoringBatteryOptimizations(),
        isTrue,
      );
    },
  );

  test(
    'entry point publishes state and handles invalid events and shutdown',
    () async {
      final service = _FakeServiceInstance();
      sshBackgroundServiceEntryPoint(service);
      expect(service.invocations.first, 'sshLogReceived');

      service.emit('sshConnect', <String, dynamic>{'name': 'missing id'});
      service.emit('sshInput', <String, dynamic>{
        'sessionId': 'missing',
        'data': 'x',
      });
      service.emit('sshResize', <String, dynamic>{
        'sessionId': 'missing',
        'width': 80,
        'height': 24,
      });
      service.emit('sshDisconnect', <String, dynamic>{'sessionId': 'missing'});
      service.emit('update', <String, dynamic>{'content': 'running'});
      service.emit('stopService', const <String, dynamic>{});
      await _waitUntil(() => service.stopped);
      expect(
        service.invocations,
        containsAll(<String>['sshLogReceived', 'sshServiceStopped']),
      );
      expect(service.stopSelfCalls, 1);
      // The event subscriptions are cancelled by shutdown, so this is ignored.
      service.emit('sshInput', <String, dynamic>{
        'sessionId': 'missing',
        'data': 'x',
      });
      expect(service.stopSelfCalls, 1);
      await service.dispose();
    },
  );

  test(
    'reports platform refusal and startup errors without updating state',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      background.startResult = false;

      await BackgroundServiceManager.start(
        connectionName: 'refused',
        showConnectionName: true,
      );
      expect(background.invocations, isNot(contains('update')));

      background.running = false;
      background.startResult = true;
      background.throwOnStart = true;
      await expectLater(
        BackgroundServiceManager.start(),
        throwsA(isA<StateError>()),
      );
      background.throwOnStart = false;
    },
  );

  test(
    'contains platform power-channel failures and preserves safe defaults',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      background.throwOnPowerCall = true;

      expect(
        await BackgroundServiceManager.isIgnoringBatteryOptimizations(),
        isFalse,
      );
      await BackgroundServiceManager.requestBatteryOptimizationExemption();
      await BackgroundServiceManager.openAppSettings();

      background.throwOnPowerCall = false;
      await BackgroundServiceManager.start();
      await Future<void>.delayed(Duration.zero);
      background.throwOnPowerCall = true;
      await BackgroundServiceManager.stop();
      background.throwOnPowerCall = false;
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for background service shutdown.');
}

final class _FakeBackgroundPlatform extends FlutterBackgroundServicePlatform {
  final Map<String, StreamController<Map<String, dynamic>?>> _events = {};
  final List<String> invocations = <String>[];
  Map<String, dynamic> lastArguments = <String, dynamic>{};
  bool running = false;
  bool throwOnConfigure = false;
  bool throwOnStart = false;
  bool startResult = true;
  bool throwOnPowerCall = false;
  int configureCalls = 0;

  @override
  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) async {
    configureCalls++;
    if (throwOnConfigure) throw StateError('configure failed');
    return true;
  }

  @override
  Future<bool> start() async {
    if (throwOnStart) throw StateError('start failed');
    running = true;
    return startResult;
  }

  @override
  Future<bool> isServiceRunning() async => running;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    invocations.add(method);
    lastArguments = args ?? <String, dynamic>{};
    if (method == 'stopService') {
      running = false;
      _events['sshServiceStopped']?.add(const <String, dynamic>{});
    }
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) => _events
      .putIfAbsent(
        method,
        () => StreamController<Map<String, dynamic>?>.broadcast(sync: true),
      )
      .stream;

  Future<void> dispose() async {
    await Future.wait(_events.values.map((controller) => controller.close()));
  }
}

final class _FakePermissionPlatform extends PermissionHandlerPlatform {
  _FakePermissionPlatform(this.status);

  final PermissionStatus status;
  int requested = 0;

  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async =>
      status;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    requested++;
    return {
      for (final permission in permissions)
        permission: PermissionStatus.granted,
    };
  }
}

final class _FakeServiceInstance implements ServiceInstance {
  final Map<String, StreamController<Map<String, dynamic>?>> _events = {};
  final List<String> invocations = <String>[];
  bool stopped = false;
  int stopSelfCalls = 0;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) =>
      invocations.add(method);

  @override
  Stream<Map<String, dynamic>?> on(String method) => _events
      .putIfAbsent(
        method,
        () => StreamController<Map<String, dynamic>?>.broadcast(sync: true),
      )
      .stream;

  void emit(String method, Map<String, dynamic> data) =>
      _events[method]?.add(data);

  @override
  Future<void> stopSelf() async {
    stopSelfCalls++;
    stopped = true;
  }

  Future<void> dispose() async {
    await Future.wait(_events.values.map((controller) => controller.close()));
  }
}
