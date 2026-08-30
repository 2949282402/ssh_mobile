import 'dart:async';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'telemetry_http_test_support.dart';

void main() {
  test(
    'bounds a held response with injectable connection and request timeouts',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestStarted = Completer<void>();
      final responseRelease = Completer<void>();
      final requestErrors = <Object>[];
      final subscription = server.listen((request) {
        unawaited(() async {
          try {
            if (!requestStarted.isCompleted) requestStarted.complete();
            await responseRelease.future;
            await request.response.close();
          } on Object catch (error) {
            requestErrors.add(error);
          }
        }());
      });
      final httpClient = HttpClient();
      const connectionTimeout = Duration(milliseconds: 40);
      const requestTimeout = Duration(milliseconds: 20);
      final transport = HttpTelemetryTransport(
        client: httpClient,
        allowLoopbackHttp: true,
        connectionTimeout: connectionTimeout,
        requestTimeout: requestTimeout,
      );
      addTearDown(() async {
        responseRelease.complete();
        await subscription.cancel();
        await server.close(force: true);
        httpClient.close(force: true);
      });

      final operation = transport.fetchRemotePolicy(
        baseUrl: 'http://127.0.0.1:${server.port}',
        authToken: 'test-token',
      );
      await requestStarted.future;

      expect(httpClient.connectionTimeout, connectionTimeout);
      await expectLater(
        operation,
        throwsA(
          isA<TelemetryUploadException>()
              .having(
                (error) => error.errorCode,
                'errorCode',
                TelemetryErrorCodes.telemetryNetworkError.code,
              )
              .having((error) => error.statusCode, 'statusCode', isNull),
        ),
      );
      expect(requestErrors, isEmpty);
    },
  );

  test('bounds held responses on every telemetry HTTP operation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final startedRequests = <Completer<void>>[];
    final releasedResponses = <Completer<void>>[];
    final activeHandlers = <Future<void>>{};
    var requestIndex = 0;
    final subscription = server.listen((request) {
      final index = requestIndex++;
      final started = startedRequests[index];
      final release = releasedResponses[index];
      late final Future<void> handler;
      handler = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
        await request.response.close();
      }();
      activeHandlers.add(handler);
      unawaited(handler.whenComplete(() => activeHandlers.remove(handler)));
    });
    final httpClient = HttpClient();
    final transport = HttpTelemetryTransport(
      client: httpClient,
      allowLoopbackHttp: true,
      connectionTimeout: const Duration(milliseconds: 40),
      requestTimeout: const Duration(milliseconds: 20),
    );
    final enrollmentRequest = const TelemetryDeviceEnrollmentRequest(
      deviceId: 'device-http',
      relayCredential: 'relay-proof',
      publicKey: 'public-key',
      timestamp: 1,
      nonce: 'nonce',
      signature: 'signature',
    );
    final rotateRequest = const TelemetryDeviceEnrollmentRequest(
      deviceId: 'device-http',
      relayCredential: 'relay-proof',
      publicKey: 'public-key',
      timestamp: 1,
      nonce: 'nonce',
      signature: 'signature',
      transcriptPath: TelemetryEndpoints.publicRotatePath,
    );
    final event = TelemetryEvents.sshSessionStarted;
    final uploadRecord = TelemetryEventRecord(
      eventId: 'evt-timeout',
      recordType: event.recordType,
      eventName: event.name,
      eventVersion: event.version,
      deviceId: 'device-http',
      sessionId: 'session-timeout',
      traceId: 'trace-timeout',
      occurredAt: DateTime.utc(2026, 8, 28),
      feature: event.feature,
      severity: event.severity,
      appVersion: '1.0.0',
      buildNumber: '1',
      platform: 'linux',
    );
    addTearDown(() async {
      for (final release in releasedResponses) {
        if (!release.isCompleted) release.complete();
      }
      if (activeHandlers.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(activeHandlers));
      }
      await subscription.cancel();
      await server.close(force: true);
      httpClient.close(force: true);
    });

    final operations = <Future<void> Function(String)>[
      (origin) async {
        await transport.authenticateDevice(
          baseUrl: origin,
          deviceId: 'device-http',
          platform: 'linux',
          appVersion: '1.0.0',
          authSecret: httpServerSecret,
          expEpoch: 1,
        );
      },
      (origin) async {
        await transport.enrollDevice(
          baseUrl: origin,
          deviceId: 'device-http',
          request: enrollmentRequest,
        );
      },
      (origin) async {
        await transport.rotateDevice(
          baseUrl: origin,
          deviceId: 'device-http',
          request: rotateRequest,
        );
      },
      (origin) async {
        await transport.fetchRemotePolicy(
          baseUrl: origin,
          authToken: 'test-token',
        );
      },
      (origin) async {
        await transport.uploadBatch(
          baseUrl: origin,
          authToken: 'test-token',
          deviceId: 'device-http',
          records: [uploadRecord],
        );
      },
    ];

    final origin = 'http://127.0.0.1:${server.port}';
    for (final invoke in operations) {
      final started = Completer<void>();
      final release = Completer<void>();
      startedRequests.add(started);
      releasedResponses.add(release);
      final operation = invoke(origin);
      // Attach the error matcher before waiting for the server. On a busy CI
      // runner the short request timeout can fire before the request callback
      // completes, which would otherwise report an unhandled async error.
      final operationExpectation = expectLater(
        operation,
        throwsA(
          isA<TelemetryUploadException>().having(
            (error) => error.errorCode,
            'errorCode',
            TelemetryErrorCodes.telemetryNetworkError.code,
          ),
        ),
      );
      await started.future;
      await operationExpectation;
      release.complete();
      if (activeHandlers.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(activeHandlers));
      }
    }
  });
}
