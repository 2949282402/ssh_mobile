import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test('client aggregate keeps authentication and lifecycle boundaries', () {
    final sessions = _FakeSessionClient();
    final events = _FakeEvents(sessions.events);
    final sdk = NetworkSdkClients(
      bootstrap: _FakeBootstrapClient(),
      authenticatedApi: _FakeAuthenticatedApiClient(),
      sessions: sessions,
      events: events,
    );

    expect(identical(sdk.sessions, sessions), isTrue);
    expect(identical(sdk.events, events), isTrue);
    expect(sdk.bootstrap, isA<BootstrapClient>());
    expect(sdk.authenticatedApi, isA<AuthenticatedApiClient>());
  });

  test(
    'typed result exposes stable retry policy without transport details',
    () {
      const result = SdkFailure<void>(
        NetworkError(code: NetworkErrorCode.timeout, message: 'safe message'),
      );

      expect(result.error.code.retryable, isTrue);
      expect(result.toString(), isNot(contains('socket')));
    },
  );
}

final class _FakeBootstrapClient implements BootstrapClient {
  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 1));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(EnrollmentRequest request) async =>
      SdkSuccess(
        DeviceEnrollment(deviceId: request.deviceId, relayCredential: 'fake'),
      );
}

final class _FakeAuthenticatedApiClient implements AuthenticatedApiClient {
  @override
  Future<SdkResult<List<PeerDescriptor>>> listPeers() async =>
      const SdkSuccess(<PeerDescriptor>[]);

  @override
  Future<SdkResult<ConnectionTicket>> requestConnection(String peerId) async =>
      SdkSuccess(ConnectionTicket(peerId: peerId, value: 'fake'));
}

final class _FakeEvents implements EventStreamClient {
  const _FakeEvents(this.events);

  @override
  final Stream<SdkEvent> events;
}

final class _FakeSessionClient implements SessionClient {
  @override
  final Stream<SdkEvent> events = const Stream<SdkEvent>.empty();

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess(null);

  @override
  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> connect(String peerId) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> disconnect(String peerId) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> disconnectRelay() async => const SdkSuccess(null);

  @override
  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async => SdkSuccess(
    SdkTransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      routeType: NetworkRouteType.unspecified,
    ),
  );

  @override
  Future<SdkResult<void>> cancel(String transferId) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) async => const SdkSuccess(null);

  @override
  Future<SdkResult<SdkRouteSnapshot>> state(String peerId) async => SdkSuccess(
    SdkRouteSnapshot(peerId: peerId, routeType: NetworkRouteType.unspecified),
  );

  @override
  Future<void> dispose() async {}
}
