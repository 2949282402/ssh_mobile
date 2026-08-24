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

  test('pinned transport connects selected IP and preserves Host', () async {
    // The transport is exercised directly against a loopback fixture here;
    // production addresses reach it only after SafeNetworkLoader validation.
    var requestCount = 0;
    String? observedHost;
    int? observedPort;
    String? observedPath;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestCount += 1;
      observedHost = request.headers.host;
      observedPort = request.headers.port;
      observedPath = request.uri.path;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('pinned response');
      await request.response.close();
    });

    final uri = Uri.parse('http://public.example.com:${server.port}/status');
    final response = await const AppWebViewPinnedTransport().get(
      uri,
      address: InternetAddress.loopbackIPv4.address,
      maxBytes: 1024,
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, 'pinned response');
    expect(requestCount, 1);
    expect(observedHost, 'public.example.com');
    expect(observedPort, server.port);
    expect(observedPath, '/status');
  });

  test('pinned transport does not follow redirects in HttpClient', () async {
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestCount += 1;
      if (request.uri.path == '/redirect') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/must-not-follow');
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('followed');
      }
      await request.response.close();
    });

    final response = await const AppWebViewPinnedTransport().get(
      Uri.parse('http://public.example.com:${server.port}/redirect'),
      address: InternetAddress.loopbackIPv4.address,
      maxBytes: 1024,
    );

    expect(response.statusCode, HttpStatus.found);
    expect(response.redirectLocation, '/must-not-follow');
    expect(requestCount, 1);
  });

  test('pinned transport rejects declared oversized responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 8
        ..write('12345678');
      await request.response.close();
    });

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
  });
}
