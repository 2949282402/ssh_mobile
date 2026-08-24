import 'dart:io';

import 'package:feature_webview/feature_webview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/webview_feature_adapters.dart';

void main() {
  test('pinned transport rejects a non-IP selected address', () async {
    await expectLater(
      const AppWebViewPinnedTransport().get(
        Uri.parse('https://public.example.com/'),
        address: 'not-an-ip',
        maxBytes: 1024,
      ),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('invalid IP'),
        ),
      ),
    );
  });

  test('pinned transport enforces authority and response boundaries', () async {
    // Keep the server, its listener, and all clients in one test and async
    // zone. Splitting them across Flutter test zones can suspend native I/O.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    String? observedHost;
    int? observedPort;
    String? observedPath;
    server.listen((request) async {
      requestCount += 1;
      observedHost = request.headers.host;
      observedPort = request.headers.port;
      observedPath = request.uri.path;
      switch (request.uri.path) {
        case '/status':
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write('pinned response');
        case '/redirect':
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/must-not-follow');
        case '/oversized':
          request.response
            ..statusCode = HttpStatus.ok
            ..contentLength = 8
            ..write('12345678');
        default:
          request.response
            ..statusCode = HttpStatus.ok
            ..write('followed');
      }
      await request.response.close();
    });

    try {
      // Production addresses first pass SafeNetworkLoader validation.
      final response = await const AppWebViewPinnedTransport().get(
        Uri.parse('http://public.example.com:${server.port}/status'),
        address: InternetAddress.loopbackIPv4.address,
        maxBytes: 1024,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, 'pinned response');
      expect(requestCount, 1);
      expect(observedHost, 'public.example.com');
      expect(observedPort, server.port);
      expect(observedPath, '/status');

      requestCount = 0;
      final redirect = await const AppWebViewPinnedTransport().get(
        Uri.parse('http://public.example.com:${server.port}/redirect'),
        address: InternetAddress.loopbackIPv4.address,
        maxBytes: 1024,
      );
      expect(redirect.statusCode, HttpStatus.found);
      expect(redirect.redirectLocation, '/must-not-follow');
      expect(requestCount, 1);

      await expectLater(
        const AppWebViewPinnedTransport().get(
          Uri.parse('http://public.example.com:${server.port}/oversized'),
          address: InternetAddress.loopbackIPv4.address,
          maxBytes: 4,
        ),
        throwsA(
          isA<ClientWebViewNetworkException>().having(
            (error) => error.message,
            'message',
            contains('oversized'),
          ),
        ),
      );
    } finally {
      await server.close(force: true);
    }
  });
}
