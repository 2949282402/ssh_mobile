import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_http_test_support.dart';

void main() {
  test(
    'enrolls, persists, authenticates with HMAC, ingests, and refreshes once',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final httpClient = HttpClient();
      final serverState = TelemetryServerState();
      server.listen((request) {
        unawaited(serverState.handle(request));
      });

      final provider = HttpEnrollmentProvider();
      final storage = MemoryTelemetryStorage();
      final client = TelemetryClient(
        config: TelemetryClientConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
          deviceId: 'device-http',
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'linux',
          releaseChannel: 'test',
          telemetryEnabled: true,
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
      expect(provider.persistedSecret, httpServerSecret);
      expect(serverState.authCalls, 1);
      expect(serverState.validHmacProofs, [true]);
      expect(serverState.ingestCalls, 1);
      expect(await storage.fetchPendingBatch(10), isEmpty);

      // The server's one-second expiresIn drives refresh; the persisted secret
      // is reused for the second HMAC proof.
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

  test('validates HTTP timeouts and sanitizes response error codes', () async {
    final connectionClient = HttpClient();
    expect(
      () => HttpTelemetryTransport(
        client: connectionClient,
        connectionTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    connectionClient.close(force: true);

    final requestClient = HttpClient();
    expect(
      () => HttpTelemetryTransport(
        client: requestClient,
        requestTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    requestClient.close(force: true);

    final responses = <String>[
      '[]',
      '{"error":{"code":"UPSTREAM_DOWN"}}',
      '{"code":"POLICY_DOWN"}',
    ];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await utf8.decodeStream(request);
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..headers.contentType = ContentType.json
        ..write(responses.removeAt(0));
      await request.response.close();
    });
    final httpClient = HttpClient();
    final transport = HttpTelemetryTransport(
      client: httpClient,
      allowLoopbackHttp: true,
    );
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      httpClient.close(force: true);
    });

    Future<TelemetryUploadException> fetchFailure() async {
      try {
        await transport.fetchRemotePolicy(
          baseUrl: 'http://127.0.0.1:${server.port}',
          authToken: 'test-token',
        );
        fail('expected policy failure');
      } on TelemetryUploadException catch (error) {
        return error;
      }
    }

    expect((await fetchFailure()).errorCode, isNull);
    expect((await fetchFailure()).errorCode, 'UPSTREAM_DOWN');
    expect((await fetchFailure()).errorCode, 'POLICY_DOWN');
  });

  test(
    'maps HTTP auth, policy, upload, and connection failures safely',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      final subscription = server.listen((request) async {
        await utf8.decodeStream(request);
        final response = request.response;
        final index = requestCount++;
        if (index == 0) {
          response
            ..statusCode = HttpStatus.unauthorized
            ..write('{}');
        } else if (index == 1) {
          response
            ..statusCode = HttpStatus.serviceUnavailable
            ..headers.contentType = ContentType.json
            ..write('{"error":{"code":"AUTH_UPSTREAM"}}');
        } else if (index == 2) {
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              '{"uploadEnabled":true,"batchSizeThreshold":5,'
              '"timeIntervalSeconds":10,"maxBatchSize":20,'
              '"clientMaxLocalRecords":100,"specialTriggers":[],'
              '"policyVersion":3}',
            );
        } else {
          response
            ..statusCode = HttpStatus.tooManyRequests
            ..headers.set('retry-after', '3')
            ..headers.contentType = ContentType.json
            ..write('{"code":"RATE_LIMITED"}');
        }
        await response.close();
      });
      final httpClient = HttpClient();
      final transport = HttpTelemetryTransport(
        client: httpClient,
        allowLoopbackHttp: true,
      );
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        httpClient.close(force: true);
      });
      final origin = 'http://127.0.0.1:${server.port}';

      await expectLater(
        transport.authenticateDevice(
          baseUrl: origin,
          deviceId: 'device-http',
          platform: 'linux',
          appVersion: '1.0.0',
          authSecret: httpServerSecret,
        ),
        throwsA(
          isA<TelemetryUploadException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.unauthorized,
          ),
        ),
      );
      await expectLater(
        transport.authenticateDevice(
          baseUrl: origin,
          deviceId: 'device-http',
          platform: 'linux',
          appVersion: '1.0.0',
          authSecret: httpServerSecret,
          expEpoch: 1,
        ),
        throwsA(
          isA<TelemetryUploadException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having((error) => error.errorCode, 'errorCode', 'AUTH_UPSTREAM'),
        ),
      );

      final policy = await transport.fetchRemotePolicy(
        baseUrl: origin,
        authToken: 'test-token',
      );
      expect(policy?.policyVersion, 3);
      expect(policy?.maxBatchSize, 20);

      final event = TelemetryEvents.sshSessionStarted;
      final record = TelemetryEventRecord(
        eventId: 'evt-http-rate-limit',
        recordType: event.recordType,
        eventName: event.name,
        eventVersion: event.version,
        deviceId: 'device-http',
        sessionId: 'session-http',
        traceId: 'trace-http',
        occurredAt: DateTime.utc(2026, 8, 28),
        feature: event.feature,
        severity: event.severity,
        appVersion: '1.0.0',
        buildNumber: '1',
        platform: 'linux',
      );
      await expectLater(
        transport.uploadBatch(
          baseUrl: origin,
          authToken: 'test-token',
          deviceId: 'device-http',
          records: [record],
        ),
        throwsA(
          isA<TelemetryUploadException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having((error) => error.retryAfterSeconds, 'retryAfter', 3)
              .having((error) => error.errorCode, 'errorCode', 'RATE_LIMITED'),
        ),
      );

      final unusedServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final unusedPort = unusedServer.port;
      await unusedServer.close(force: true);
      final failedClient = HttpClient();
      final failedTransport = HttpTelemetryTransport(
        client: failedClient,
        allowLoopbackHttp: true,
        requestTimeout: const Duration(seconds: 1),
      );
      addTearDown(() => failedClient.close(force: true));
      await expectLater(
        failedTransport.fetchRemotePolicy(
          baseUrl: 'http://127.0.0.1:$unusedPort',
          authToken: '',
        ),
        throwsA(
          isA<TelemetryUploadException>().having(
            (error) => error.errorCode,
            'errorCode',
            TelemetryErrorCodes.telemetryNetworkError.code,
          ),
        ),
      );
    },
  );

  test('rejects a 2xx upload response that omits results', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await utf8.decodeStream(request);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{}');
      await request.response.close();
    });
    final httpClient = HttpClient();
    final transport = HttpTelemetryTransport(
      client: httpClient,
      allowLoopbackHttp: true,
    );
    final event = TelemetryEvents.sshSessionStarted;
    final record = TelemetryEventRecord(
      eventId: 'evt-missing-results',
      recordType: event.recordType,
      eventName: event.name,
      eventVersion: event.version,
      deviceId: 'device-http',
      sessionId: 'session-http',
      traceId: 'trace-http',
      occurredAt: DateTime.utc(2026, 8, 28),
      feature: event.feature,
      severity: event.severity,
      appVersion: '1.0.0',
      buildNumber: '1',
      platform: 'linux',
    );
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      httpClient.close(force: true);
    });

    await expectLater(
      transport.uploadBatch(
        baseUrl: 'http://127.0.0.1:${server.port}',
        authToken: 'test-token',
        deviceId: 'device-http',
        records: [record],
      ),
      throwsA(
        isA<TelemetryUploadException>()
            .having((error) => error.statusCode, 'statusCode', 502)
            .having(
              (error) => error.errorCode,
              'errorCode',
              'INVALID_RESPONSE',
            ),
      ),
    );
  });

  test(
    'does not replay enrollment credentials across an HTTP redirect',
    () async {
      final server = await RedirectTelemetryServer.start(
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
    final server = await RedirectTelemetryServer.start(
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
