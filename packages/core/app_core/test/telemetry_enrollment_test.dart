import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

const _serverSecret =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

final class _EnrollmentProvider
    implements
        TelemetryDeviceEnrollmentProvider,
        TelemetryDeviceEnrollmentPathProvider {
  _EnrollmentProvider(this.secret, {this.failPersistence = false});

  final String secret;
  bool failPersistence;
  int requestCalls = 0;
  int pathRequestCalls = 0;
  final List<String> requestedPaths = <String>[];
  int persistCalls = 0;
  String? persistedSecret;

  @override
  Future<TelemetryDeviceEnrollmentRequest?> createRequest({
    required String baseUrl,
    required String deviceId,
  }) async {
    requestCalls++;
    return const TelemetryDeviceEnrollmentRequest(
      deviceId: 'device-a',
      relayCredential: 'relay-credential',
      publicKey: 'public-key',
      timestamp: 1,
      nonce: 'nonce',
      signature: 'signature',
    );
  }

  @override
  Future<TelemetryDeviceEnrollmentRequest?> createRequestForPath({
    required String baseUrl,
    required String deviceId,
    required String transcriptPath,
  }) async {
    pathRequestCalls++;
    requestedPaths.add(transcriptPath);
    return TelemetryDeviceEnrollmentRequest(
      deviceId: deviceId,
      relayCredential: 'relay-credential',
      publicKey: 'public-key',
      timestamp: 1,
      nonce: 'nonce-$pathRequestCalls',
      signature: 'signature-$pathRequestCalls',
      transcriptPath: transcriptPath,
    );
  }

  @override
  Future<void> persistSecret(String value) async {
    persistCalls++;
    if (failPersistence) {
      throw StateError('secure storage unavailable');
    }
    persistedSecret = value;
  }
}

final class _EnrollmentTransport implements TelemetryTransport {
  _EnrollmentTransport({this.expiresInSeconds = 3600});

  final int expiresInSeconds;
  int enrollmentCalls = 0;
  int rotationCalls = 0;
  int authCalls = 0;
  int uploadCalls = 0;
  final List<String?> authSecrets = <String?>[];
  bool alreadyEnrolled = false;
  bool rejectWrongSecret = true;

  @override
  Future<TelemetryAuthResult?> authenticateDevice({
    required String baseUrl,
    required String deviceId,
    required String platform,
    required String appVersion,
    String? authSecret,
    int? expEpoch,
  }) async {
    authCalls++;
    authSecrets.add(authSecret);
    if (rejectWrongSecret && authSecret != _serverSecret) {
      throw const TelemetryUploadException(
        'Telemetry device authentication rejected',
        statusCode: 401,
        errorCode: 'AUTH_FAILED',
      );
    }
    return TelemetryAuthResult(
      token: 'auth-token-$authCalls',
      expiresInSeconds: expiresInSeconds,
    );
  }

  @override
  Future<TelemetryEnrollmentResult?> enrollDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async {
    enrollmentCalls++;
    if (alreadyEnrolled) {
      throw const TelemetryUploadException('ALREADY_ENROLLED', statusCode: 409);
    }
    return TelemetryEnrollmentResult(deviceId: deviceId, secret: _serverSecret);
  }

  @override
  Future<TelemetryEnrollmentResult?> rotateDevice({
    required String baseUrl,
    required String deviceId,
    required TelemetryDeviceEnrollmentRequest request,
  }) async => _rotate(deviceId);

  TelemetryEnrollmentResult _rotate(String deviceId) {
    rotationCalls++;
    return TelemetryEnrollmentResult(deviceId: deviceId, secret: _serverSecret);
  }

  @override
  Future<TelemetryUploadPolicy?> fetchRemotePolicy({
    required String baseUrl,
    required String authToken,
  }) async => TelemetryUploadPolicy.defaultPolicy();

  @override
  Future<TelemetryBatchUploadResult> uploadBatch({
    required String baseUrl,
    required String authToken,
    required String deviceId,
    required List<TelemetryEventRecord> records,
  }) async {
    uploadCalls++;
    return TelemetryBatchUploadResult(
      ackResults: [
        for (final record in records)
          TelemetryAckResult(eventId: record.eventId, status: 'accepted'),
      ],
    );
  }
}

TelemetryClient _client({
  required TelemetryStorage storage,
  required TelemetryTransport transport,
  TelemetryDeviceEnrollmentProvider? provider,
  String? deviceEnrollmentSecret,
}) => TelemetryClient(
  config: TelemetryClientConfig(
    baseUrl: 'https://relay.test',
    deviceId: 'device-a',
    appVersion: '1.0.0',
    buildNumber: '1',
    platform: 'linux',
    releaseChannel: 'test',
    telemetryEnabled: true,
    deviceEnrollmentSecret: deviceEnrollmentSecret,
    deviceEnrollmentProvider: provider,
    policyFetchIntervalSeconds: 0,
  ),
  storage: storage,
  transport: transport,
  initialPolicy: const TelemetryUploadPolicy(
    uploadEnabled: true,
    batchSizeThreshold: 100,
    timeIntervalSeconds: 3600,
    maxBatchSize: 10,
    clientMaxLocalRecords: 100,
    specialTriggers: <String>[],
    policyVersion: 1,
  ),
);

void main() {
  test(
    'missing telemetry secret enrolls through existing Relay identity',
    () async {
      final storage = MemoryTelemetryStorage();
      final provider = _EnrollmentProvider(_serverSecret);
      final transport = _EnrollmentTransport();
      final client = _client(
        storage: storage,
        transport: transport,
        provider: provider,
      );
      addTearDown(client.dispose);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.enrollmentCalls, 1);
      expect(provider.requestCalls, 1);
      expect(provider.persistCalls, 1);
      expect(provider.persistedSecret, _serverSecret);
      expect(transport.authCalls, 1);
      expect(transport.authSecrets, [_serverSecret]);
      expect(transport.uploadCalls, 1);
    },
  );

  test('client honors server expiresIn before authenticating again', () async {
    final storage = MemoryTelemetryStorage();
    final provider = _EnrollmentProvider(_serverSecret);
    final transport = _EnrollmentTransport(expiresInSeconds: 1);
    final client = _client(
      storage: storage,
      transport: transport,
      provider: provider,
    );
    addTearDown(client.dispose);

    await client.record(event: TelemetryEvents.sshSessionStarted);
    await client.flush();
    await Future<void>.delayed(const Duration(seconds: 2));
    await client.record(event: TelemetryEvents.sshSessionStarted);
    await client.flush();

    expect(transport.authCalls, 2);
    expect(transport.enrollmentCalls, 1);
    expect(transport.authSecrets, [_serverSecret, _serverSecret]);
    expect(transport.uploadCalls, 2);
  });

  test(
    'does not cache an enrolled secret until secure persistence succeeds',
    () async {
      final storage = MemoryTelemetryStorage();
      final provider = _EnrollmentProvider(
        _serverSecret,
        failPersistence: true,
      );
      final transport = _EnrollmentTransport();
      final client = _client(
        storage: storage,
        transport: transport,
        provider: provider,
      );
      addTearDown(client.dispose);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(provider.persistCalls, 1);
      expect(provider.persistedSecret, isNull);
      expect(transport.authCalls, 0);
      expect(transport.uploadCalls, 0);

      provider.failPersistence = false;
      await client.flush();

      expect(transport.enrollmentCalls, 2);
      expect(provider.persistCalls, 2);
      expect(transport.authCalls, 1);
      expect(transport.authSecrets.single, _serverSecret);
      expect(transport.uploadCalls, 1);
    },
  );

  test(
    'wrong enrollment secret is rejected and leaves the batch pending',
    () async {
      final storage = MemoryTelemetryStorage();
      final transport = _EnrollmentTransport();
      final client = _client(
        storage: storage,
        transport: transport,
        deviceEnrollmentSecret: 'wrong-enrollment-secret',
      );
      addTearDown(client.dispose);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.enrollmentCalls, 0);
      expect(transport.authCalls, 1);
      expect(transport.uploadCalls, 0);
      expect(await storage.fetchPendingBatch(10), hasLength(1));
      expect(client.latestDiagnostics.lastSyncError, contains('HTTP 401'));
      expect(
        client.latestDiagnostics.lastSyncError,
        isNot(contains('wrong-enrollment-secret')),
      );
    },
  );

  test(
    'ALREADY_ENROLLED uses a fresh proof on the explicit rotate route',
    () async {
      final storage = MemoryTelemetryStorage();
      final provider = _EnrollmentProvider(_serverSecret);
      final transport = _EnrollmentTransport()..alreadyEnrolled = true;
      final client = _client(
        storage: storage,
        transport: transport,
        provider: provider,
      );
      addTearDown(client.dispose);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.enrollmentCalls, 1);
      expect(transport.rotationCalls, 1);
      expect(provider.pathRequestCalls, 1);
      expect(
        provider.requestedPaths.single,
        TelemetryEndpoints.publicRotatePath,
      );
      expect(provider.persistCalls, 1);
      expect(transport.authCalls, 1);
      expect(transport.uploadCalls, 1);
    },
  );

  test(
    'missing or malformed Relay proof fails closed without authenticating',
    () async {
      final storage = MemoryTelemetryStorage();
      final provider = _EnrollmentProvider(_serverSecret);
      final transport = _EnrollmentTransport();
      final client = _client(
        storage: storage,
        transport: transport,
        provider: _MissingProofProvider(),
      );
      addTearDown(client.dispose);

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(transport.enrollmentCalls, 0);
      expect(transport.authCalls, 0);
      expect(transport.uploadCalls, 0);
      expect(await storage.fetchPendingBatch(10), hasLength(1));
      // Keep the real provider referenced so this test's setup cannot
      // accidentally drift into an admin-secret path.
      expect(provider.persistCalls, 0);
    },
  );
}

final class _MissingProofProvider implements TelemetryDeviceEnrollmentProvider {
  @override
  Future<TelemetryDeviceEnrollmentRequest?> createRequest({
    required String baseUrl,
    required String deviceId,
  }) async => null;

  @override
  Future<void> persistSecret(String secret) async {}
}
