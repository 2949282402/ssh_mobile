// Relay 生命周期 Owner 的纯 Dart 独立测试。

import 'dart:async';
import 'dart:typed_data';

import 'package:feature_lan_share/src/domain/lan_relay_ports.dart';
import 'package:feature_lan_share/src/features/lan_share/services/lan_relay_coordinator.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('rejects non-origin endpoint without touching capability', () async {
    final settings = _FakeSettings();
    final capability = _FakeCapability();
    final coordinator = _buildCoordinator(
      settings: settings,
      capability: capability,
    );

    final save = await coordinator.saveEndpoint(
      Uri.parse('http://relay.example.test/path?token=secret'),
    );
    final enroll = await coordinator.enroll(
      endpoint: Uri.parse('https://user@relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    expect(save, isA<NetworkFailure<void>>());
    expect(enroll, isA<NetworkFailure<void>>());
    expect(capability.ensureCalls, 0);
    expect(settings.relayEndpoint, isEmpty);

    await coordinator.close();
  });

  test(
    'maps rejected settings writes to an invalid argument failure',
    () async {
      final settings = _FakeSettings(rejectWrites: true);
      final coordinator = _buildCoordinator(settings: settings);

      final result = await coordinator.saveEndpoint(
        Uri.parse('https://relay.example.test'),
      );

      expect(result, isA<NetworkFailure<void>>());
      expect(
        (result as NetworkFailure<void>).error.code,
        NetworkErrorCode.invalidArgument,
      );
      await coordinator.close();
    },
  );

  test(
    'rejects missing configuration and disconnects without facade',
    () async {
      final coordinator = _buildCoordinator(settings: _FakeSettings());

      final connect = await coordinator.connectConfigured();
      final disconnect = await coordinator.disconnect();

      expect(
        (connect as NetworkFailure<void>).error.code,
        NetworkErrorCode.relayError,
      );
      expect(disconnect, isA<NetworkSuccess<void>>());
      await coordinator.close();
    },
  );

  test('enrollment without a facade fails with noRoute', () async {
    final coordinator = _buildCoordinator(settings: _FakeSettings());

    final result = await coordinator.enroll(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    expect(
      (result as NetworkFailure<void>).error.code,
      NetworkErrorCode.noRoute,
    );
    await coordinator.close();
  });

  test(
    'missing native credential distinguishes expired and absent storage',
    () async {
      final expired = _FakeEnrollment()..configurationAvailable = false;
      final expiredCoordinator = _buildCoordinator(
        settings: _FakeSettings(),
        enrollment: expired,
      );
      await expiredCoordinator.attachFacade(_FakeFacade());

      final expiredResult = await expiredCoordinator.enroll(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );
      expect(
        (expiredResult as NetworkFailure<void>).error.code,
        NetworkErrorCode.credentialExpired,
      );
      await expiredCoordinator.close();

      final absent = _FakeEnrollment(storeAfterEnroll: false)
        ..configurationAvailable = false;
      final absentCoordinator = _buildCoordinator(
        settings: _FakeSettings(),
        enrollment: absent,
      );
      await absentCoordinator.attachFacade(_FakeFacade());

      final absentResult = await absentCoordinator.enroll(
        endpoint: Uri.parse('https://relay.example.test'),
        enrollmentToken: '0123456789abcdef',
      );
      expect(
        (absentResult as NetworkFailure<void>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      await absentCoordinator.close();
    },
  );

  test('saves normalized origin and reports connecting state', () async {
    final settings = _FakeSettings();
    final enrollment = _FakeEnrollment();
    final facade = _FakeFacade();
    final coordinator = _buildCoordinator(
      settings: settings,
      enrollment: enrollment,
    );
    await coordinator.attachFacade(facade);

    final saved = await coordinator.saveEndpoint(
      Uri.parse('https://relay.example.test/'),
    );
    facade.emitRelayState(RelayConnectionState.connecting);
    await _flushEvents();

    expect(saved, isA<NetworkSuccess<void>>());
    expect(settings.relayEndpoint, 'https://relay.example.test');
    expect(coordinator.status.isConnecting, isTrue);

    enrollment.enrollResult = _failure(NetworkErrorCode.invalidArgument);
    final rejectedEnrollment = await coordinator.enroll(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: 'short',
    );
    expect(rejectedEnrollment, isA<NetworkFailure<void>>());
    expect(coordinator.status.enrolled, isFalse);

    await coordinator.close();
    await facade.dispose();
  });

  test(
    'expired stored credential refreshes before a missing facade fails',
    () async {
      final settings = _FakeSettings(
        relayEndpoint: 'https://relay.example.test',
      );
      final enrollment = _FakeEnrollment(
        stored: true,
        refreshResult: _failure(NetworkErrorCode.noRoute),
      );
      final coordinator = _buildCoordinator(
        settings: settings,
        enrollment: enrollment,
      );

      final result = await coordinator.connectConfigured();
      await _eventually(() => enrollment.refreshCalls == 1);

      expect(result, isA<NetworkFailure<void>>());
      expect(
        (result as NetworkFailure<void>).error.code,
        NetworkErrorCode.credentialExpired,
      );
      expect(coordinator.status.error?.code, NetworkErrorCode.noRoute);

      await coordinator.close();
    },
  );

  test('owns relay state but only borrows facade and capability', () async {
    final settings = _FakeSettings();
    final capability = _FakeCapability();
    final enrollment = _FakeEnrollment();
    final facade = _FakeFacade();
    var notifications = 0;
    final coordinator = _buildCoordinator(
      settings: settings,
      capability: capability,
      enrollment: enrollment,
      onChanged: () => notifications++,
    );
    await coordinator.attachFacade(facade);

    final result = await coordinator.enroll(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );
    facade.emitRelayState(RelayConnectionState.connected);
    await _flushEvents();

    expect(result, isA<NetworkSuccess<void>>());
    expect(settings.relayEndpoint, 'https://relay.example.test');
    expect(facade.configureRelayCalls, 1);
    expect(coordinator.status.enrolled, isTrue);
    expect(coordinator.status.isConnected, isTrue);
    expect(coordinator.nativeRelayActive, isTrue);
    expect(notifications, greaterThan(0));

    final disconnected = await coordinator.disconnect();
    expect(disconnected, isA<NetworkSuccess<void>>());
    expect(coordinator.status.state, RelayConnectionState.disconnected);

    await coordinator.close();
    expect(facade.disposed, isFalse);
    expect(capability.disposed, isFalse);
    expect(enrollment.disposeCalls, 1);
    expect(() => coordinator.attachFacade(_FakeFacade()), throwsStateError);
    await facade.dispose();
  });

  test('capability refusal fails closed before native commands', () async {
    final settings = _FakeSettings(relayEndpoint: 'https://relay.example.test');
    final capability = _FakeCapability(refuse: true);
    final facade = _FakeFacade();
    final coordinator = _buildCoordinator(
      settings: settings,
      capability: capability,
    );
    await coordinator.attachFacade(facade);

    final result = await coordinator.connectConfigured();

    expect(result, isA<NetworkFailure<void>>());
    expect(
      (result as NetworkFailure<void>).error.code,
      NetworkErrorCode.relayError,
    );
    expect(capability.ensureCalls, 1);
    expect(facade.configureRelayCalls, 0);
    expect(facade.disconnectRelayCalls, 0);

    await coordinator.close();
    await facade.dispose();
  });

  test('credential expiry refreshes once and reconnects', () async {
    final settings = _FakeSettings();
    final enrollment = _FakeEnrollment();
    final facade = _FakeFacade();
    final coordinator = _buildCoordinator(
      settings: settings,
      enrollment: enrollment,
    );
    await coordinator.attachFacade(facade);
    await coordinator.enroll(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    facade.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.credentialExpired,
        message: 'expired',
        operation: NetworkOperation.connectRelay,
        retryDisposition: RetryDisposition.refreshCredentialThenRetry,
      ),
    );
    await _eventually(() => facade.configureRelayCalls == 2);

    expect(enrollment.refreshCalls, 1);
    expect(coordinator.status.enrolled, isTrue);
    expect(coordinator.status.error, isNull);

    await coordinator.close();
    await facade.dispose();
  });

  test('bounded backoff retries while noRetry remains terminal', () async {
    final settings = _FakeSettings();
    final facade = _FakeFacade();
    final coordinator = _buildCoordinator(
      settings: settings,
      retryDelays: const <Duration>[Duration(milliseconds: 5)],
    );
    await coordinator.attachFacade(facade);
    await coordinator.enroll(
      endpoint: Uri.parse('https://relay.example.test'),
      enrollmentToken: '0123456789abcdef',
    );

    facade.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.relayError,
        message: 'temporary',
        operation: NetworkOperation.connectRelay,
      ),
    );
    await _eventually(() => facade.configureRelayCalls == 2);

    facade.emitRelayState(
      RelayConnectionState.failed,
      error: const NetworkError(
        code: NetworkErrorCode.relayError,
        message: 'terminal',
        operation: NetworkOperation.connectRelay,
        retryDisposition: RetryDisposition.noRetry,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(facade.configureRelayCalls, 2);
    expect(coordinator.status.reconnectAttempt, 0);
    expect(
      coordinator.status.error?.retryDisposition,
      RetryDisposition.noRetry,
    );

    await coordinator.close();
    await facade.dispose();
  });

  test('external endpoint replacement revokes prior enrollment', () async {
    final settings = _FakeSettings();
    final enrollment = _FakeEnrollment();
    final facade = _FakeFacade();
    final coordinator = _buildCoordinator(
      settings: settings,
      enrollment: enrollment,
    );
    await coordinator.attachFacade(facade);
    await coordinator.enroll(
      endpoint: Uri.parse('https://relay-a.example.test'),
      enrollmentToken: '0123456789abcdef',
    );
    expect(coordinator.status.enrolled, isTrue);

    await settings.setRelayEndpoint('https://relay-b.example.test');
    await _eventually(() => enrollment.clearCalls == 1);

    expect(facade.disconnectRelayCalls, 2);
    expect(coordinator.status.enrolled, isFalse);
    expect(coordinator.status.error, isNull);

    final connect = await coordinator.connectConfigured();
    expect(connect, isA<NetworkFailure<void>>());
    expect(
      (connect as NetworkFailure<void>).error.code,
      NetworkErrorCode.authenticationFailed,
    );

    await coordinator.clearEnrollment();
    expect(settings.relayEndpoint, isEmpty);
    expect(enrollment.clearCalls, 2);

    await coordinator.close();
    await facade.dispose();
  });
}

LanRelayCoordinator _buildCoordinator({
  required _FakeSettings settings,
  _FakeCapability? capability,
  _FakeEnrollment? enrollment,
  void Function()? onChanged,
  List<Duration> retryDelays = const <Duration>[Duration(milliseconds: 10)],
}) => LanRelayCoordinator(
  appSettings: settings,
  logger: _FakeLogger(),
  enrollmentService: enrollment ?? _FakeEnrollment(),
  capability: capability ?? _FakeCapability(),
  onChanged: onChanged ?? () {},
  retryDelays: retryDelays,
);

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}

NetworkFailure<void> _failure(NetworkErrorCode code) => NetworkFailure<void>(
  NetworkError(
    code: code,
    message: 'test failure',
    operation: NetworkOperation.connectRelay,
  ),
);

final class _FakeSettings implements LanRelaySettingsPort {
  _FakeSettings({this.relayEndpoint = '', this.rejectWrites = false});

  @override
  String relayEndpoint;
  final bool rejectWrites;
  final Set<void Function()> _listeners = <void Function()>{};

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  Future<void> setRelayEndpoint(String endpoint) async {
    if (rejectWrites) throw ArgumentError('settings rejected endpoint');
    relayEndpoint = endpoint;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

final class _FakeLogger implements LanRelayLoggerPort {
  final List<String> warnings = <String>[];

  @override
  void warning(String message, {String? details}) => warnings.add(message);
}

final class _FakeCapability implements LanRelayCapabilityPort {
  _FakeCapability({this.refuse = false});

  final bool refuse;
  int ensureCalls = 0;
  bool disposed = false;

  @override
  Future<void> ensureWebSocketRelay() async {
    ensureCalls++;
    if (refuse) throw UnsupportedError('relay unavailable');
  }
}

final class _FakeEnrollment implements LanRelayEnrollmentPort {
  _FakeEnrollment({
    this.stored = false,
    this.storeAfterEnroll = true,
    this.refreshResult = const NetworkSuccess<void>(null),
  });

  bool enrolled = false;
  bool stored;
  final bool storeAfterEnroll;
  bool configurationAvailable = true;
  NetworkResult<void> enrollResult = const NetworkSuccess<void>(null);
  NetworkResult<void> refreshResult;
  int refreshCalls = 0;
  int clearCalls = 0;
  int disposeCalls = 0;

  @override
  Future<NetworkResult<void>> enroll(
    RelaySettings settings,
    String enrollmentToken,
  ) async {
    final result = enrollResult;
    if (result is NetworkSuccess<void>) {
      enrolled = true;
      stored = storeAfterEnroll;
    }
    return result;
  }

  @override
  Future<NetworkResult<void>> refreshCredential(RelaySettings settings) async {
    refreshCalls++;
    final result = refreshResult;
    if (result is NetworkSuccess<void>) {
      enrolled = true;
      stored = true;
      configurationAvailable = true;
    }
    return result;
  }

  @override
  Future<bool> hasStoredCredential(RelaySettings settings) async => stored;

  @override
  Future<bool> isEnrolled(RelaySettings settings) async =>
      enrolled && configurationAvailable;

  @override
  Future<RelayNativeConfiguration?> nativeConfiguration(
    RelaySettings settings,
  ) async => enrolled && configurationAvailable
      ? RelayNativeConfiguration(
          endpoint: settings.endpoint,
          credential: 'credential',
          signingSeed: Uint8List(32),
        )
      : null;

  @override
  Future<void> clearEnrollment() async {
    clearCalls++;
    enrolled = false;
    stored = false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

final class _FakeFacade implements NetworkFacade {
  final StreamController<NetworkEvent> _events =
      StreamController<NetworkEvent>.broadcast();
  int configureRelayCalls = 0;
  int disconnectRelayCalls = 0;
  int _eventSequence = 0;
  bool disposed = false;
  NetworkResult<void> configureResult = const NetworkSuccess<void>(null);
  NetworkResult<void> disconnectResult = const NetworkSuccess<void>(null);

  @override
  Stream<NetworkEvent> get events => _events.stream;

  void emitRelayState(RelayConnectionState state, {NetworkError? error}) {
    _events.add(
      RelayStateChanged(
        eventId: 'relay-event-${++_eventSequence}',
        timestamp: DateTime.now(),
        state: state,
        error: error,
      ),
    );
  }

  @override
  Future<NetworkResult<void>> configureRelay(RelayConfig config) async {
    configureRelayCalls++;
    return configureResult;
  }

  @override
  Future<NetworkResult<void>> disconnectRelay() async {
    disconnectRelayCalls++;
    return disconnectResult;
  }

  @override
  Future<NetworkResult<void>> start(NetworkRuntimeConfig config) async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> stop() async => const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> connectPeer(
    String peerId, {
    PeerConfig? peer,
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async => const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> disconnectPeer(String peerId) async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<TransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) async => NetworkSuccess<TransferSession>(
    TransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      routeType: NetworkRouteType.lan,
    ),
  );

  @override
  Future<NetworkResult<void>> cancelTransfer(String transferId) async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> respondToIncomingTransfer({
    required String transferId,
    required bool accept,
  }) async => const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> sendMessage({
    required String peerId,
    required Uint8List payload,
    CommunicationClass communicationClass = CommunicationClass.reliableMessage,
  }) async => const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<RouteSnapshot>> peerState(String peerId) async =>
      NetworkSuccess<RouteSnapshot>(
        RouteSnapshot(peerId: peerId, routeType: NetworkRouteType.lan),
      );

  @override
  RealtimeSession createRealtimeSession({
    required String realtimeId,
    required String peerId,
  }) => throw UnimplementedError('not used in this test');

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}
