import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test('client aggregate keeps authentication and lifecycle boundaries', () {
    final sessions = _FakeSessionClient();
    final events = _FakeEvents(sessions.events);
    final realtime = _FakeRealtimeClient();
    final sdk = NetworkSdkClients(
      bootstrap: _FakeBootstrapClient(),
      authenticatedApi: _FakeAuthenticatedApiClient(),
      sessions: sessions,
      realtime: realtime,
      events: events,
    );

    expect(identical(sdk.sessions, sessions), isTrue);
    expect(identical(sdk.events, events), isTrue);
    expect(sdk.bootstrap, isA<BootstrapClient>());
    expect(sdk.authenticatedApi, isA<AuthenticatedApiClient>());
    expect(identical(sdk.realtime, realtime), isTrue);
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

  test('bootstrap client keeps enrollment unauthenticated and typed', () async {
    final executor = _FakeExecutor([
      _response(204),
      _response(200, <String, dynamic>{
        'credential': 'credential',
        'expires_at': 200,
        'server_time': 100,
        'protocol_version': 1,
      }),
    ]);
    final client = JsonBootstrapClient(executor: executor);

    final probe = await client.probe(Uri.parse('https://relay.example'));
    final enrollment = await client.enroll(
      Uri.parse('https://relay.example'),
      EnrollmentRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        enrollmentToken: 'enrollment-token',
        platform: 'windows',
      ),
    );

    expect(probe, isA<SdkSuccess<BootstrapMetadata>>());
    expect(enrollment, isA<SdkSuccess<DeviceEnrollment>>());
    final request = executor.requests[1];
    expect(request.headers.containsKey('authorization'), isFalse);
    final body = jsonDecode(utf8.decode(request.body!)) as Map<String, dynamic>;
    expect(body['device_id'], 'device-1');
    expect(body['protocol_version'], 1);
    expect(body['platform'], 'windows');
  });

  test(
    'authenticated client refreshes a bearer token once after 401',
    () async {
      final executor = _FakeExecutor([
        _response(401),
        _response(200, <String, dynamic>{
          'peers': [
            {'peer_id': 'peer-1', 'display_name': 'Peer 1'},
          ],
        }),
      ]);
      final auth = _FakeAuthSession();
      final client = JsonAuthenticatedApiClient(
        executor: executor,
        authSession: auth,
        routes: AuthenticatedApiRoutes(
          listPeers: Uri.parse('https://control.example/v1/peers'),
          requestConnection: (peerId) =>
              Uri.parse('https://control.example/v1/peers/$peerId/connect'),
        ),
      );

      final result = await client.listPeers();

      expect(result, isA<SdkSuccess<List<PeerDescriptor>>>());
      expect(
        (result as SdkSuccess<List<PeerDescriptor>>).data.single.peerId,
        'peer-1',
      );
      expect(executor.requests[0].headers['authorization'], 'Bearer old-token');
      expect(executor.requests[1].headers['authorization'], 'Bearer new-token');
      expect(auth.refreshCount, 1);
      expect(auth.invalidated, isFalse);
    },
  );

  test(
    'authenticated client does not issue a request without a token',
    () async {
      final executor = _FakeExecutor(const <SdkResponse>[]);
      final auth = _FakeAuthSession()..token = null;
      final client = JsonAuthenticatedApiClient(
        executor: executor,
        authSession: auth,
        routes: AuthenticatedApiRoutes(
          listPeers: Uri.parse('https://control.example/v1/peers'),
          requestConnection: (peerId) =>
              Uri.parse('https://control.example/$peerId'),
        ),
      );

      final result = await client.listPeers();

      expect(result, isA<SdkFailure<List<PeerDescriptor>>>());
      expect(
        (result as SdkFailure<List<PeerDescriptor>>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(executor.requests, isEmpty);
    },
  );
}

SdkResponse _response(int statusCode, [Map<String, dynamic>? body]) =>
    SdkResponse(
      statusCode: statusCode,
      body: Uint8List.fromList(
        body == null ? <int>[] : utf8.encode(jsonEncode(body)),
      ),
    );

final class _FakeExecutor implements SdkRequestExecutor {
  _FakeExecutor(Iterable<SdkResponse> responses)
    : _responses = List<SdkResponse>.from(responses);

  final List<SdkResponse> _responses;
  final List<SdkRequest> requests = <SdkRequest>[];

  @override
  Future<SdkResponse> execute(SdkRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('no fake response');
    return _responses.removeAt(0);
  }
}

final class _FakeAuthSession implements AuthSessionProvider {
  String? token = 'old-token';
  int refreshCount = 0;
  bool invalidated = false;

  @override
  Future<String?> readAccessToken() async => token;

  @override
  Future<String?> refreshAccessToken() async {
    refreshCount++;
    token = 'new-token';
    return token;
  }

  @override
  Future<void> invalidate() async {
    invalidated = true;
    token = null;
  }
}

final class _FakeBootstrapClient implements BootstrapClient {
  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 1));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async => SdkSuccess(
    DeviceEnrollment(
      deviceId: request.deviceId,
      relayCredential: 'fake',
      expiresAt: DateTime.utc(2030),
      serverTime: DateTime.utc(2029),
      protocolVersion: 1,
    ),
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

final class _FakeRealtimeClient implements RealtimeClient {
  @override
  RealtimeSession createSession({
    required String realtimeId,
    required String peerId,
  }) => throw UnimplementedError();

  @override
  Future<void> dispose() async {}
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
