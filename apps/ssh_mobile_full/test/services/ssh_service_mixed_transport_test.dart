import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/ssh_service.dart';

import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService mixed mobile transport state', () {
    late TestStorageAdapter storage;
    late SshService sshService;
    late _FakeBackgroundServicePlatform backgroundPlatform;
    late _StallingNativeConnector nativeConnector;
    late FlutterBackgroundServicePlatform? previousBackgroundPlatform;
    late PermissionHandlerPlatform? previousPermissionPlatform;
    late Future<void> nativeConnect;

    setUp(() async {
      previousBackgroundPlatform = _tryReadBackgroundPlatform();
      previousPermissionPlatform = PermissionHandlerPlatform.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      backgroundPlatform = _FakeBackgroundServicePlatform();
      FlutterBackgroundServicePlatform.instance = backgroundPlatform;
      PermissionHandlerPlatform.instance = _GrantedPermissionPlatform();

      storage = TestStorageAdapter();
      await _addConnection(storage, 'native-connection');
      await _addConnection(storage, 'background-connection');
      nativeConnector = _StallingNativeConnector();
      sshService = createTestSshService(
        storage,
        nativeStreamConnector: nativeConnector,
        peerIdResolver: (config) =>
            config.id == 'native-connection' ? 'peer-native' : null,
      );
      await sshService.ensureInitialized();
    });

    tearDown(() async {
      await nativeConnector.closeAll();
      try {
        await nativeConnect;
      } catch (_) {
        // Closing the stalled test stream intentionally aborts the handshake.
      }
      await sshService.close();
      await storage.shutdown();
      storage.dispose();
      await backgroundPlatform.dispose();
      final previousBackground = previousBackgroundPlatform;
      if (previousBackground != null) {
        FlutterBackgroundServicePlatform.instance = previousBackground;
      }
      final previousPermission = previousPermissionPlatform;
      if (previousPermission != null) {
        PermissionHandlerPlatform.instance = previousPermission;
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('public overview merges native and background sessions', () async {
      nativeConnect = sshService.connect(
        'native-connection',
        sessionId: 'native-session',
      );
      await _waitForConnecting(sshService, 'native-session');

      final backgroundConnect = sshService.connect(
        'background-connection',
        sessionId: 'background-session',
      );
      await _waitForConnecting(sshService, 'background-session');
      await _waitForInvocation(backgroundPlatform, 'sshConnect');
      backgroundPlatform.emit('sshStateChanged', {
        'sessionId': 'background-session',
        'state': 'connected',
      });
      await backgroundConnect;
      backgroundPlatform.emit('sshOverviewUpdated', {
        'overview': {
          'background-connection': {
            'count': 1,
            'latestState': 'connected',
            'hasConnected': true,
          },
        },
        'windowCount': 1,
      });
      await _pump();

      final overview = sshService.serverOverviewSnapshot;
      expect(overview.windowCount, 2);
      expect(overview.forConnection('native-connection').count, 1);
      expect(
        overview.forConnection('native-connection').latestState,
        SshConnectionState.connecting,
      );
      expect(overview.forConnection('background-connection').count, 1);
      expect(
        overview.forConnection('background-connection').latestState,
        SshConnectionState.connected,
      );
      expect(
        overview.forConnection('background-connection').hasConnected,
        isTrue,
      );
    });

    test(
      'background service stops after the last background session closes',
      () async {
        nativeConnect = sshService.connect(
          'native-connection',
          sessionId: 'native-session',
        );
        await _waitForConnecting(sshService, 'native-session');

        final backgroundConnect = sshService.connect(
          'background-connection',
          sessionId: 'background-session',
        );
        await _waitForConnecting(sshService, 'background-session');
        await _waitForInvocation(backgroundPlatform, 'sshConnect');
        backgroundPlatform.emit('sshStateChanged', {
          'sessionId': 'background-session',
          'state': 'connected',
        });
        await backgroundConnect;
        expect(backgroundPlatform.running, isTrue);

        await sshService.disconnectSession('background-session');
        await _waitUntil(() => !backgroundPlatform.running);

        expect(backgroundPlatform.stopRequests, 1);
        expect(sshService.getSession('native-session'), isNotNull);
        expect(sshService.serverOverviewSnapshot.windowCount, 1);
        expect(
          sshService.serverOverviewSnapshot
              .forConnection('native-connection')
              .count,
          1,
        );
        expect(
          sshService.serverOverviewSnapshot
              .forConnection('background-connection')
              .count,
          0,
        );
      },
    );
  });
}

FlutterBackgroundServicePlatform? _tryReadBackgroundPlatform() {
  try {
    return FlutterBackgroundServicePlatform.instance;
  } on Object {
    return null;
  }
}

Future<void> _addConnection(TestStorageAdapter storage, String id) async {
  await storage.connectionRepository.addConnection(
    ConnectionConfig(
      id: id,
      name: id,
      host: '198.51.100.10',
      username: 'fixture-user',
      hostKeyFingerprint: 'SHA256:fixture',
    ),
  );
  await storage.credentialRepository.saveCredentials(
    connectionId: id,
    password: 'fixture-password',
  );
}

Future<void> _waitForConnecting(SshService service, String sessionId) async {
  await _waitUntil(
    () => service.getSession(sessionId)?.state == SshConnectionState.connecting,
  );
}

Future<void> _waitForInvocation(
  _FakeBackgroundServicePlatform platform,
  String method,
) async {
  await _waitUntil(() => platform.invocations.contains(method));
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for the expected mixed transport state.');
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

final class _FakeBackgroundServicePlatform
    extends FlutterBackgroundServicePlatform {
  final Map<String, StreamController<Map<String, dynamic>?>> _events = {};
  final List<String> invocations = <String>[];
  bool running = false;
  int stopRequests = 0;

  @override
  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) async => true;

  @override
  Future<bool> start() async {
    running = true;
    return true;
  }

  @override
  Future<bool> isServiceRunning() async => running;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    invocations.add(method);
    if (method == 'stopService') {
      stopRequests++;
      running = false;
      emit('sshServiceStopped', const <String, dynamic>{});
    }
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) {
    return _events
        .putIfAbsent(
          method,
          () => StreamController<Map<String, dynamic>?>.broadcast(sync: true),
        )
        .stream;
  }

  void emit(String method, Map<String, dynamic> data) {
    _events[method]?.add(data);
  }

  Future<void> dispose() async {
    await Future.wait<void>(
      _events.values.map((controller) => controller.close()),
    );
  }
}

final class _GrantedPermissionPlatform extends PermissionHandlerPlatform {
  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async {
    return PermissionStatus.granted;
  }

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    return <Permission, PermissionStatus>{
      for (final permission in permissions)
        permission: PermissionStatus.granted,
    };
  }
}

final class _StallingNativeConnector
    implements ssh_core.SshNativeStreamConnector {
  final Set<_StallingNativeStream> _streams = <_StallingNativeStream>{};

  @override
  Future<ssh_core.SshNativeStream> open({
    required String peerId,
    String service = ssh_core.kSshNativeStreamService,
    String? traceId,
  }) async {
    final stream = _StallingNativeStream();
    _streams.add(stream);
    return stream;
  }

  @override
  Future<void> closeAll() async {
    for (final stream in _streams.toList(growable: false)) {
      stream.destroy();
    }
  }
}

final class _StallingNativeStream implements ssh_core.SshNativeStream {
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast(sync: true);
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('fixture stream is closed');
  }

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    unawaited(_incoming.close());
    _done.complete();
  }
}
