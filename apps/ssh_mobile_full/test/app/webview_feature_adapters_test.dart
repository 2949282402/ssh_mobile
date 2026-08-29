import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:feature_webview/feature_webview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/webview_feature_adapters.dart';

void main() {
  test('DNS resolver returns deduplicated localhost addresses', () async {
    final addresses = await const AppWebViewDnsResolver().lookup('localhost');
    expect(addresses, isNotEmpty);
    expect(addresses, orderedEquals(addresses.toSet().toList()));
  });

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
    // The adapter itself uses HttpClient's connectionFactory to pin a
    // validated IP while retaining the requested authority. Override the
    // client in this Flutter test so no flutter_tester native socket bind is
    // needed; the factory is still inspected for authority enforcement.
    final clients = <_FakeHttpClient>[];
    final transport = const AppWebViewPinnedTransport();
    final loopback = InternetAddress.loopbackIPv4.address;
    final port = 43123;

    await HttpOverrides.runZoned(
      () async {
        final response = await transport.get(
          Uri.parse('http://public.example.com:$port/status'),
          address: loopback,
          maxBytes: 1024,
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(response.body, 'pinned response');
        expect(clients.single.request?.uri.host, 'public.example.com');
        expect(clients.single.request?.uri.port, port);
        expect(clients.single.request?.uri.path, '/status');
        expect(
          clients.single.request?.headers.value(HttpHeaders.connectionHeader),
          'close',
        );
        expect(clients.single.request?.followRedirects, isFalse);
        expect(clients.single.request?.maxRedirects, 0);
        expect(clients.single.findProxy?.call(Uri()), 'DIRECT');

        final connectionFactory = clients.single.connectionFactory;
        expect(connectionFactory, isNotNull);
        await expectLater(
          connectionFactory!(
            Uri.parse('http://attacker.example.com:$port/status'),
            null,
            null,
          ),
          throwsA(
            isA<ClientWebViewNetworkException>().having(
              (error) => error.message,
              'message',
              contains('unpinned'),
            ),
          ),
        );
        await expectLater(
          connectionFactory!(
            Uri.parse('http://public.example.com:$port/status'),
            'proxy.example.com',
            null,
          ),
          throwsA(isA<ClientWebViewNetworkException>()),
        );
        await expectLater(
          connectionFactory!(
            Uri.parse('http://public.example.com:$port/status'),
            null,
            8080,
          ),
          throwsA(isA<ClientWebViewNetworkException>()),
        );
        await expectLater(
          connectionFactory!(
            Uri.parse('https://public.example.com:$port/status'),
            null,
            null,
          ),
          throwsA(isA<ClientWebViewNetworkException>()),
        );
        await expectLater(
          connectionFactory!(
            Uri.parse('http://public.example.com:43124/status'),
            null,
            null,
          ),
          throwsA(isA<ClientWebViewNetworkException>()),
        );

        final defaultPortResponse = await transport.get(
          Uri.parse('http://public.example.com/status'),
          address: loopback,
          maxBytes: 1024,
        );
        expect(defaultPortResponse.statusCode, HttpStatus.ok);
        final defaultPortFactory = clients.last.connectionFactory!;
        await expectLater(
          defaultPortFactory(
            Uri.parse('http://attacker.example.com/status'),
            null,
            null,
          ),
          throwsA(isA<ClientWebViewNetworkException>()),
        );
        final httpsResponse = await transport.get(
          Uri.parse('https://public.example.com/status'),
          address: loopback,
          maxBytes: 1024,
        );
        expect(httpsResponse.statusCode, HttpStatus.ok);
        final httpsFactory = clients.last.connectionFactory!;
        await expectLater(
          httpsFactory(
            Uri.parse('https://attacker.example.com/status'),
            null,
            null,
          ),
          throwsA(isA<ClientWebViewNetworkException>()),
        );

        final redirect = await transport.get(
          Uri.parse('http://public.example.com:$port/redirect'),
          address: loopback,
          maxBytes: 1024,
        );
        expect(redirect.statusCode, HttpStatus.found);
        expect(redirect.redirectLocation, '/must-not-follow');

        await expectLater(
          transport.get(
            Uri.parse('http://public.example.com:$port/oversized'),
            address: loopback,
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

        await expectLater(
          transport.get(
            Uri.parse('http://public.example.com:$port/stream-oversized'),
            address: loopback,
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
      },
      createHttpClient: (_) {
        final client = _FakeHttpClient(_responseFor);
        clients.add(client);
        return client;
      },
    );
    expect(clients, hasLength(6));
    expect(clients.every((client) => client.closed), isTrue);
  });
}

_FakeHttpClientResponse _responseFor(Uri uri) {
  return switch (uri.path) {
    '/status' => _FakeHttpClientResponse(
      statusCode: HttpStatus.ok,
      contentType: ContentType.text,
      body: 'pinned response',
    ),
    '/redirect' => _FakeHttpClientResponse(
      statusCode: HttpStatus.found,
      headers: <String, String>{HttpHeaders.locationHeader: '/must-not-follow'},
    ),
    '/oversized' => _FakeHttpClientResponse(
      statusCode: HttpStatus.ok,
      declaredLength: 8,
      body: '12345678',
    ),
    '/stream-oversized' => _FakeHttpClientResponse(
      statusCode: HttpStatus.ok,
      body: '12345',
    ),
    _ => _FakeHttpClientResponse(statusCode: HttpStatus.notFound),
  };
}

final class _FakeHttpClient extends Fake implements HttpClient {
  _FakeHttpClient(this.responseFactory);

  final _FakeHttpClientResponse Function(Uri uri) responseFactory;
  _FakeHttpClientRequest? request;
  bool closed = false;

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  String Function(Uri uri)? findProxy;

  @override
  Future<ConnectionTask<Socket>> Function(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  )?
  connectionFactory;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final next = _FakeHttpClientRequest(uri, responseFactory(uri));
    request = next;
    return next;
  }

  @override
  void close({bool force = false}) => closed = true;
}

final class _FakeHttpClientRequest extends Fake implements HttpClientRequest {
  _FakeHttpClientRequest(this.uri, this.response);

  @override
  final Uri uri;
  final _FakeHttpClientResponse response;
  final _FakeHttpHeaders requestHeaders = _FakeHttpHeaders();

  @override
  final String method = 'GET';

  @override
  HttpHeaders get headers => requestHeaders;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  Future<HttpClientResponse> close() async => response;
}

final class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse({
    required this.statusCode,
    this.declaredLength = -1,
    String body = '',
    ContentType? contentType,
    Map<String, String> headers = const <String, String>{},
  }) : _body = utf8.encode(body),
       _headers = _FakeHttpHeaders(
         values: <String, String>{
           ...headers,
           if (contentType != null)
             HttpHeaders.contentTypeHeader: contentType.mimeType,
         },
       );

  @override
  final int statusCode;
  final int declaredLength;
  final List<int> _body;
  final _FakeHttpHeaders _headers;

  @override
  int get contentLength => declaredLength;

  @override
  HttpHeaders get headers => _headers;

  @override
  String get reasonPhrase => '';

  @override
  bool get isRedirect => const <int>{
    HttpStatus.movedPermanently,
    HttpStatus.found,
    HttpStatus.seeOther,
    HttpStatus.temporaryRedirect,
    HttpStatus.permanentRedirect,
  }.contains(statusCode);

  @override
  bool get persistentConnection => false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_body).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeHttpHeaders extends Fake implements HttpHeaders {
  _FakeHttpHeaders({Map<String, String> values = const <String, String>{}}) {
    for (final entry in values.entries) {
      set(entry.key, entry.value);
    }
  }

  final Map<String, List<String>> _values = <String, List<String>>{};

  String _key(String name) => name.toLowerCase();

  @override
  String? value(String name) => _values[_key(name)]?.firstOrNull;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[_key(name)] = <String>['$value'];
  }
}
