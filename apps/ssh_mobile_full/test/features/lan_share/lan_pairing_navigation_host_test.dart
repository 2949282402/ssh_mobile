import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/features/lan_share/viewmodels/lan_share_viewmodel.dart';
import 'package:ssh_mobile/features/lan_share/views/lan_pairing_navigation_host.dart';
import 'package:ssh_mobile/features/lan_share/views/lan_pairing_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_share_models.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';

LanDevice _device(String id, {String alias = 'Peer', int port = 53317}) {
  return LanDevice(
    id: id,
    alias: alias,
    ip: '192.168.1.20',
    port: port,
    deviceType: LanDeviceType.desktop,
    osName: 'windows',
    lastSeen: DateTime.now(),
  );
}

LanPairingRequest _request({
  required String deviceId,
  required String sessionId,
  required bool isIncoming,
  String alias = 'Peer',
  int port = 53317,
  Duration lifetime = const Duration(minutes: 1),
}) {
  return LanPairingRequest(
    device: _device(deviceId, alias: alias, port: port),
    sessionId: sessionId,
    isIncoming: isIncoming,
    expiresAt: DateTime.now().add(lifetime),
  );
}

class _FakeTransferService extends Fake implements LanTransferService {
  @override
  Stream<LanDevice> get handshakeSuccessStream => const Stream.empty();
}

class _FakeLanShareViewModel extends Fake implements LanShareViewModel {
  final StreamController<LanPairingRequest> _requests =
      StreamController<LanPairingRequest>.broadcast(sync: true);
  final Map<String, LanPairingRequest> _latestRequests = {};
  final Set<VoidCallback> _listeners = {};

  @override
  final LanSecurityService securityService = LanSecurityService();

  @override
  final LanTransferService transferService = _FakeTransferService();

  @override
  Stream<LanPairingRequest> get pairingRequestStream => _requests.stream;

  @override
  Future<void> initialize() async {}

  @override
  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestRequests[sessionId];
    return request == null || request.isExpired ? null : request;
  }

  void emit(LanPairingRequest request) {
    _latestRequests[request.sessionId] = request;
    _requests.add(request);
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  bool get hasListeners => _listeners.isNotEmpty;

  Future<void> close() => _requests.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LanPairingNavigationQueue', () {
    test(
      'merges a different-session incoming request into the active peer',
      () {
        final queue = LanPairingNavigationQueue();
        final outgoing = _request(
          deviceId: 'peer-a',
          sessionId: 'outgoing-session',
          isIncoming: false,
          alias: 'Old alias',
        );
        final incoming = _request(
          deviceId: 'peer-a',
          sessionId: 'incoming-session',
          isIncoming: true,
          alias: 'Resolved alias',
          port: 62001,
          lifetime: const Duration(minutes: 2),
        );

        expect(queue.add(outgoing), LanPairingNavigationDecision.open);
        expect(queue.add(incoming), LanPairingNavigationDecision.updateActive);

        final active = queue.activeRequest!;
        expect(active.sessionId, outgoing.sessionId);
        expect(active.isIncoming, isTrue);
        expect(active.device.alias, 'Resolved alias');
        expect(active.device.port, 62001);
        expect(active.expiresAt, incoming.expiresAt);
        expect(queue.pendingCount, 0);
      },
    );

    test('an outgoing duplicate cannot downgrade an incoming active role', () {
      final queue = LanPairingNavigationQueue();
      queue.add(
        _request(
          deviceId: 'peer-a',
          sessionId: 'incoming-session',
          isIncoming: true,
        ),
      );

      queue.add(
        _request(
          deviceId: 'peer-a',
          sessionId: 'outgoing-session',
          isIncoming: false,
        ),
      );

      expect(queue.activeRequest!.isIncoming, isTrue);
    });

    test('queues other peers in FIFO order without overwriting them', () {
      final queue = LanPairingNavigationQueue();
      queue.add(
        _request(deviceId: 'peer-a', sessionId: 'session-a', isIncoming: false),
      );
      queue.add(
        _request(deviceId: 'peer-b', sessionId: 'session-b', isIncoming: false),
      );
      queue.add(
        _request(deviceId: 'peer-c', sessionId: 'session-c', isIncoming: false),
      );
      queue.add(
        _request(
          deviceId: 'peer-b',
          sessionId: 'session-b-incoming',
          isIncoming: true,
        ),
      );

      expect(queue.pendingCount, 2);
      expect(queue.completeActive()!.device.id, 'peer-b');
      expect(queue.activeRequest!.isIncoming, isTrue);
      expect(queue.completeActive()!.device.id, 'peer-c');
      expect(queue.completeActive(), isNull);
    });

    test('ignores already expired requests', () {
      final queue = LanPairingNavigationQueue();
      final expired = _request(
        deviceId: 'peer-a',
        sessionId: 'expired',
        isIncoming: true,
        lifetime: const Duration(seconds: -1),
      );

      expect(queue.add(expired), LanPairingNavigationDecision.ignored);
      expect(queue.activeRequest, isNull);
    });
  });

  testWidgets(
    'incoming role emitted before screen subscription reaches active page',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final viewModel = _FakeLanShareViewModel();
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<LanShareViewModel>.value(value: viewModel),
            ChangeNotifierProvider<AppSettings>.value(value: AppSettings()),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            builder: (context, child) => LanPairingNavigationHost(
              navigatorKey: navigatorKey,
              child: child ?? const SizedBox.shrink(),
            ),
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );

      viewModel.emit(
        _request(
          deviceId: 'peer-a',
          sessionId: 'outgoing-session',
          isIncoming: false,
          alias: 'Outgoing peer',
        ),
      );
      // Emit synchronously before the pushed route builds and subscribes.
      viewModel.emit(
        _request(
          deviceId: 'peer-a',
          sessionId: 'incoming-session',
          isIncoming: true,
          alias: 'Incoming peer',
          port: 62001,
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final screen = tester.widget<LanPairingScreen>(
        find.byType(LanPairingScreen),
      );
      expect(screen.sessionId, 'outgoing-session');
      expect(screen.isIncomingRequest, isTrue);
      expect(screen.initialAlias, 'Incoming peer');
      expect(find.text('安全配对请求'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await viewModel.close();
    },
  );

  testWidgets('reciprocal invitation preserves a PIN already being typed', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final viewModel = _FakeLanShareViewModel();
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareViewModel>.value(value: viewModel),
          ChangeNotifierProvider<AppSettings>.value(value: AppSettings()),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => LanPairingNavigationHost(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );

    viewModel.emit(
      _request(
        deviceId: 'peer-a',
        sessionId: 'outgoing-session',
        isIncoming: false,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), '123456');

    viewModel.emit(
      _request(
        deviceId: 'peer-a',
        sessionId: 'incoming-session',
        isIncoming: true,
        alias: 'Updated peer',
      ),
    );
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    final screen = tester.widget<LanPairingScreen>(
      find.byType(LanPairingScreen),
    );
    expect(field.controller?.text, '123456');
    expect(screen.isIncomingRequest, isTrue);
    expect(screen.initialAlias, 'Updated peer');

    await tester.pumpWidget(const SizedBox.shrink());
    await viewModel.close();
  });
}
