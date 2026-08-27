import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

const _httpServerSecret =
    'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

void main() {
  test(
    'enrolls, persists, authenticates with HMAC, ingests, and refreshes once',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final httpClient = HttpClient();
      final serverState = _TelemetryServerState();
      server.listen((request) {
        unawaited(serverState.handle(request));
      });

      final provider = _HttpEnrollmentProvider();
      final storage = MemoryTelemetryStorage();
      final client = TelemetryClient(
        config: TelemetryClientConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
          deviceId: 'device-http',
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'linux',
          releaseChannel: 'test',
          deviceEnrollmentProvider: provider,
          policyFetchIntervalSeconds: 0,
        ),
        storage: storage,
        transport: HttpTelemetryTransport(
          client: httpClient,
          allowLoopbackHttp: true,
        ),
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
      addTearDown(() async {
        await client.dispose();
        httpClient.close(force: true);
        await server.close(force: true);
      });

      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(serverState.errors, isEmpty);
      expect(serverState.enrollmentCalls, 1);
      expect(provider.requestCalls, 1);
      expect(provider.persistedSecret, _httpServerSecret);
      expect(serverState.authCalls, 1);
      expect(serverState.validHmacProofs, [true]);
      expect(serverState.ingestCalls, 1);
      expect(await storage.fetchPendingBatch(10), isEmpty);

      // The server's one-second expiresIn must drive refresh. The enrollment
      // secret is already persisted and must be reused for the second HMAC.
      await Future<void>.delayed(const Duration(seconds: 2));
      await client.record(event: TelemetryEvents.sshSessionStarted);
      await client.flush();

      expect(serverState.enrollmentCalls, 1);
      expect(serverState.authCalls, 2);
      expect(serverState.validHmacProofs, [true, true]);
      expect(serverState.ingestCalls, 2);
      expect(await storage.fetchPendingBatch(10), isEmpty);
    },
  );

  test(
    'rejects non-loopback HTTP origins before sending enrollment proofs',
    () async {
      final httpClient = HttpClient();
      final transport = HttpTelemetryTransport(client: httpClient);
      addTearDown(() => httpClient.close(force: true));

      await expectLater(
        transport.enrollDevice(
          baseUrl: 'http://telemetry.example.test',
          deviceId: 'device-http',
          request: const TelemetryDeviceEnrollmentRequest(
            deviceId: 'device-http',
            relayCredential: 'relay-proof',
            publicKey: 'public-key',
            timestamp: 1,
            nonce: 'nonce',
            signature: 'signature',
          ),
        ),
        throwsA(
          isA<TelemetryUploadException>().having(
            (error) => error.statusCode,
            'status',
            400,
          ),
        ),
      );
    },
  );

  test(
    'does not replay enrollment credentials across an HTTP redirect',
    () async {
      final server = await _RedirectServer.start(
        sourcePath: TelemetryEndpoints.publicEnrollPath,
        statusCode: HttpStatus.temporaryRedirect,
      );
      final httpClient = HttpClient();
      final transport = HttpTelemetryTransport(
        client: httpClient,
        allowLoopbackHttp: true,
      );
      addTearDown(() async {
        httpClient.close(force: true);
        await server.close();
      });

      await expectLater(
        transport.enrollDevice(
          baseUrl: server.origin,
          deviceId: 'device-http',
          request: const TelemetryDeviceEnrollmentRequest(
            deviceId: 'device-http',
            relayCredential: 'relay-proof',
            publicKey: 'public-key',
            timestamp: 1,
            nonce: 'nonce',
            signature: 'signature',
          ),
        ),
        throwsA(
          isA<TelemetryUploadException>().having(
            (error) => error.statusCode,
            'status',
            HttpStatus.temporaryRedirect,
          ),
        ),
      );

      expect(server.sourceRequests, 1);
      expect(server.captureRequests, 0);
      expect(server.errors, isEmpty);
    },
  );

  test('does not replay bearer credentials across an HTTP redirect', () async {
    final server = await _RedirectServer.start(
      sourcePath: TelemetryEndpoints.publicPolicyPath,
      statusCode: HttpStatus.found,
    );
    final httpClient = HttpClient();
    final transport = HttpTelemetryTransport(
      client: httpClient,
      allowLoopbackHttp: true,
    );
    addTearDown(() async {
      httpClient.close(force: true);
      await server.close();
    });

    await expectLater(
      transport.fetchRemotePolicy(
        baseUrl: server.origin,
        authToken: 'bearer-secret',
      ),
      throwsA(
        isA<TelemetryUploadException>().having(
          (error) => error.statusCode,
          'status',
          HttpStatus.found,
        ),
      ),
    );

    expect(server.sourceRequests, 1);
    expect(server.captureRequests, 0);
    expect(server.captureAuthorization, isNull);
    expect(server.errors, isEmpty);
  });
}

final class _RedirectServer {
  _RedirectServer._({
    required this._server,
    required this.sourcePath,
    required this.statusCode,
  });

  static Future<_RedirectServer> start({
    required String sourcePath,
    required int statusCode,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectServer = _RedirectServer._(
      server: server,
      sourcePath: sourcePath,
      statusCode: statusCode,
    );
    redirectServer._subscription = server.listen(redirectServer._onRequest);
    return redirectServer;
  }

  final HttpServer _server;
  final String sourcePath;
  final int statusCode;
  late final StreamSubscription<HttpRequest> _subscription;
  final Set<Future<void>> _activeRequests = <Future<void>>{};
  final List<Object> errors = <Object>[];
  int sourceRequests = 0;
  int captureRequests = 0;
  String? captureAuthorization;
  String? captureBody;

  String get origin => 'http://127.0.0.1:${_server.port}';

  void _onRequest(HttpRequest request) {
    late final Future<void> operation;
    operation = _handle(request);
    _activeRequests.add(operation);
    unawaited(operation.whenComplete(() => _activeRequests.remove(operation)));
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == sourcePath) {
        sourceRequests++;
        if (request.method == 'POST') {
          await utf8.decodeStream(request);
        }
        request.response
          ..statusCode = statusCode
          ..headers.contentLength = 0
          ..headers.set(HttpHeaders.locationHeader, '$origin/capture');
        await request.response.close();
        return;
      }

      if (request.uri.path == '/capture') {
        captureRequests++;
        captureAuthorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        captureBody = await utf8.decodeStream(request);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = 0;
        await request.response.close();
        return;
      }

      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentLength = 0;
      await request.response.close();
    } on Object catch (error) {
      errors.add(error);
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..headers.contentLength = 0;
        await request.response.close();
      } on Object {
        // The request may already be closed; preserve the original failure.
      }
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    if (_activeRequests.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_activeRequests));
    }
    await _server.close(force: true);
  }
}

final class _HttpEnrollmentProvider
    implements TelemetryDeviceEnrollmentProvider {
  int requestCalls = 0;
  String? persistedSecret;

  @override
  Future<TelemetryDeviceEnrollmentRequest?> createRequest({
    required String baseUrl,
    required String deviceId,
  }) async {
    requestCalls++;
    return const TelemetryDeviceEnrollmentRequest(
      deviceId: 'device-http',
      relayCredential: 'relay-proof',
      publicKey: 'public-key',
      timestamp: 1,
      nonce: 'nonce',
      signature: 'signature',
    );
  }

  @override
  Future<void> persistSecret(String secret) async {
    persistedSecret = secret;
  }
}

final class _TelemetryServerState {
  final List<Object> errors = <Object>[];
  final List<bool> validHmacProofs = <bool>[];
  int enrollmentCalls = 0;
  int authCalls = 0;
  int ingestCalls = 0;
  final Set<String> issuedTokens = <String>{};

  Future<void> handle(HttpRequest request) async {
    try {
      switch (request.uri.path) {
        case TelemetryEndpoints.publicEnrollPath:
          await _handleEnroll(request);
        case TelemetryEndpoints.publicAuthPath:
          await _handleAuth(request);
        case TelemetryEndpoints.publicIngestPath:
          await _handleIngest(request);
        default:
          _writeJson(request.response, 404, <String, dynamic>{});
      }
    } on Object catch (error) {
      errors.add(error);
      _writeJson(request.response, 500, <String, dynamic>{});
    }
  }

  Future<void> _handleEnroll(HttpRequest request) async {
    enrollmentCalls++;
    final body = await _readJson(request);
    expect(body['deviceId'], 'device-http');
    expect(body['relayCredential'], 'relay-proof');
    _writeJson(request.response, 201, <String, dynamic>{
      'deviceId': 'device-http',
      'secret': _httpServerSecret,
    });
  }

  Future<void> _handleAuth(HttpRequest request) async {
    authCalls++;
    final body = await _readJson(request);
    final deviceId = body['deviceId'];
    final expEpoch = body['expEpoch'];
    final proof = body['proof'];
    final valid =
        deviceId == 'device-http' &&
        expEpoch is int &&
        proof ==
            const HmacTelemetryProofFactory().sign(
              enrollmentSecret: _httpServerSecret,
              deviceId: 'device-http',
              expEpoch: expEpoch,
            );
    validHmacProofs.add(valid);
    if (!valid) {
      _writeJson(request.response, 401, <String, dynamic>{
        'error': <String, dynamic>{'code': 'AUTH_FAILED'},
      });
      return;
    }
    final token = 'token-$authCalls';
    issuedTokens.add(token);
    _writeJson(request.response, 200, <String, dynamic>{
      'deviceId': 'device-http',
      'token': token,
      'expiresIn': 1,
    });
  }

  Future<void> _handleIngest(HttpRequest request) async {
    ingestCalls++;
    final token = request.headers.value('authorization');
    if (request.headers.value('x-device-id') != 'device-http' ||
        token == null ||
        !issuedTokens.contains(token.replaceFirst('Bearer ', ''))) {
      _writeJson(request.response, 401, <String, dynamic>{});
      return;
    }
    final body = await _readJson(request);
    final records = body['records'];
    if (records is! List) {
      _writeJson(request.response, 400, <String, dynamic>{});
      return;
    }
    _writeJson(request.response, 200, <String, dynamic>{
      'results': [
        for (final record in records)
          <String, dynamic>{
            'eventId': (record as Map<String, dynamic>)['eventId'],
            'status': 'accepted',
          },
      ],
    });
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  void _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    unawaited(response.close());
  }
}
