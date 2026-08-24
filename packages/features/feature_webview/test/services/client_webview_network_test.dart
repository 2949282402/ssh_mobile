import 'package:feature_webview/feature_webview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('safe loader validates and pins every redirect hop', () async {
    final resolver = _FakeResolver({
      'start.example.com': [
        ['93.184.216.34'],
      ],
      'final.example.com': [
        ['142.250.72.14'],
      ],
    });
    final transport = _FakePinnedTransport((uri, address) {
      if (uri.host == 'start.example.com') {
        return const ClientWebViewTransportResponse(
          statusCode: 302,
          redirectLocation: 'https://final.example.com/page',
          body: '',
        );
      }
      return const ClientWebViewTransportResponse(
        statusCode: 200,
        contentType: 'text/html; charset=utf-8',
        body: '<html>ok</html>',
      );
    });
    final loader = ClientWebViewSafeNetworkLoader(
      resolver: resolver,
      transport: transport,
    );

    final page = await loader.load(Uri.parse('https://start.example.com/'));

    expect(page.finalUri, Uri.parse('https://final.example.com/page'));
    expect(transport.calls, [
      ('https://start.example.com/', '93.184.216.34'),
      ('https://final.example.com/page', '142.250.72.14'),
    ]);
  });

  test('safe loader blocks private DNS answers before transport', () async {
    final transport = _FakePinnedTransport((uri, address) {
      fail('transport must not run for a private DNS answer');
    });
    final loader = ClientWebViewSafeNetworkLoader(
      resolver: _FakeResolver({
        'mixed.example.com': [
          ['93.184.216.34', '10.0.0.7'],
        ],
      }),
      transport: transport,
    );

    await expectLater(
      loader.load(Uri.parse('https://mixed.example.com/')),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('non-global IPv4'),
        ),
      ),
    );
    expect(transport.calls, isEmpty);
  });

  test('safe loader detects DNS rebinding on a same-host redirect', () async {
    final resolver = _FakeResolver({
      'rebind.example.com': [
        ['93.184.216.34'],
        ['127.0.0.1'],
      ],
    });
    final transport = _FakePinnedTransport(
      (uri, address) => const ClientWebViewTransportResponse(
        statusCode: 302,
        redirectLocation: '/second-hop',
        body: '',
      ),
    );
    final loader = ClientWebViewSafeNetworkLoader(
      resolver: resolver,
      transport: transport,
    );

    await expectLater(
      loader.load(Uri.parse('https://rebind.example.com/first-hop')),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('non-global IPv4'),
        ),
      ),
    );
    expect(transport.calls, [
      ('https://rebind.example.com/first-hop', '93.184.216.34'),
    ]);
    expect(resolver.calls['rebind.example.com'], 2);
  });

  test('safe loader rejects a redirect to a private literal', () async {
    final transport = _FakePinnedTransport(
      (uri, address) => const ClientWebViewTransportResponse(
        statusCode: 302,
        redirectLocation: 'http://169.254.169.254/latest/meta-data',
        body: '',
      ),
    );
    final loader = ClientWebViewSafeNetworkLoader(
      resolver: _FakeResolver({
        'public.example.com': [
          ['93.184.216.34'],
        ],
      }),
      transport: transport,
    );

    await expectLater(
      loader.load(Uri.parse('https://public.example.com/')),
      throwsA(isA<ClientWebViewNetworkException>()),
    );
    expect(transport.calls, hasLength(1));
  });

  test('safe loader handles public literals without consulting DNS', () async {
    final resolver = _ThrowingResolver();
    final transport = _FakePinnedTransport(
      (uri, address) => const ClientWebViewTransportResponse(
        statusCode: 200,
        contentType: 'text/plain',
        body: 'ok',
      ),
    );
    final loader = ClientWebViewSafeNetworkLoader(
      resolver: resolver,
      transport: transport,
    );

    final page = await loader.load(Uri.parse('https://8.8.8.8/status'));

    expect(page.body, 'ok');
    expect(transport.calls.single.$2, '8.8.8.8');
  });

  test(
    'safe loader maps DNS failure and empty answers to stable errors',
    () async {
      final transport = _FakePinnedTransport((uri, address) {
        fail('transport must not run when DNS fails');
      });
      final failed = ClientWebViewSafeNetworkLoader(
        resolver: _ThrowingResolver(),
        transport: transport,
      );
      final empty = ClientWebViewSafeNetworkLoader(
        resolver: _FakeResolver({
          'empty.example.com': const [[]],
        }),
        transport: transport,
      );

      await expectLater(
        failed.load(Uri.parse('https://failed.example.com/')),
        throwsA(
          isA<ClientWebViewNetworkException>().having(
            (error) => error.message,
            'message',
            'DNS resolution failed.',
          ),
        ),
      );
      await expectLater(
        empty.load(Uri.parse('https://empty.example.com/')),
        throwsA(
          isA<ClientWebViewNetworkException>().having(
            (error) => error.message,
            'message',
            'DNS returned no usable addresses.',
          ),
        ),
      );
    },
  );

  test('safe loader rejects redirect loops and missing locations', () async {
    final resolver = _FakeResolver({
      'loop.example.com': [
        ['93.184.216.34'],
      ],
    });
    final loop = ClientWebViewSafeNetworkLoader(
      resolver: resolver,
      transport: _FakePinnedTransport(
        (uri, address) => const ClientWebViewTransportResponse(
          statusCode: 302,
          redirectLocation: '/',
          body: '',
        ),
      ),
    );
    final missing = ClientWebViewSafeNetworkLoader(
      resolver: resolver,
      transport: _FakePinnedTransport(
        (uri, address) =>
            const ClientWebViewTransportResponse(statusCode: 302, body: ''),
      ),
    );

    await expectLater(
      loop.load(Uri.parse('https://loop.example.com/')),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('redirect loop'),
        ),
      ),
    );
    await expectLater(
      missing.load(Uri.parse('https://loop.example.com/missing')),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('without a location'),
        ),
      ),
    );
  });

  test('safe loader enforces the configured redirect bound', () async {
    final loader = ClientWebViewSafeNetworkLoader(
      maxRedirects: 0,
      resolver: _FakeResolver({
        'redirect.example.com': [
          ['93.184.216.34'],
        ],
      }),
      transport: _FakePinnedTransport(
        (uri, address) => const ClientWebViewTransportResponse(
          statusCode: 307,
          redirectLocation: '/next',
          body: '',
        ),
      ),
    );

    await expectLater(
      loader.load(Uri.parse('https://redirect.example.com/')),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('excessive redirects'),
        ),
      ),
    );
  });

  test(
    'safe loader maps malformed redirect locations to a stable error',
    () async {
      final loader = ClientWebViewSafeNetworkLoader(
        resolver: _FakeResolver({
          'redirect.example.com': [
            ['93.184.216.34'],
          ],
        }),
        transport: _FakePinnedTransport(
          (uri, address) => const ClientWebViewTransportResponse(
            statusCode: 302,
            redirectLocation: 'https://[invalid',
            body: '',
          ),
        ),
      );

      await expectLater(
        loader.load(Uri.parse('https://redirect.example.com/invalid')),
        throwsA(
          isA<ClientWebViewNetworkException>().having(
            (error) => error.message,
            'message',
            contains('invalid redirect location'),
          ),
        ),
      );
    },
  );

  test('safe loader rejects bad status and response content type', () async {
    final resolver = _FakeResolver({
      'response.example.com': [
        ['93.184.216.34'],
      ],
    });
    final status = ClientWebViewSafeNetworkLoader(
      resolver: resolver,
      transport: _FakePinnedTransport(
        (uri, address) => const ClientWebViewTransportResponse(
          statusCode: 503,
          contentType: 'text/plain',
          body: '',
        ),
      ),
    );
    final content = ClientWebViewSafeNetworkLoader(
      resolver: resolver,
      transport: _FakePinnedTransport(
        (uri, address) => const ClientWebViewTransportResponse(
          statusCode: 200,
          contentType: 'application/octet-stream',
          body: 'binary',
        ),
      ),
    );

    await expectLater(
      status.load(Uri.parse('https://response.example.com/status')),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('HTTP 503'),
        ),
      ),
    );
    await expectLater(
      content.load(Uri.parse('https://response.example.com/content')),
      throwsA(
        isA<ClientWebViewNetworkException>().having(
          (error) => error.message,
          'message',
          contains('non-text'),
        ),
      ),
    );
  });
}

final class _FakeResolver implements ClientWebViewDnsResolver {
  _FakeResolver(this.answers);

  final Map<String, List<List<String>>> answers;
  final Map<String, int> calls = {};

  @override
  Future<List<String>> lookup(String host) async {
    final call = calls.update(host, (value) => value + 1, ifAbsent: () => 1);
    final hostAnswers = answers[host];
    if (hostAnswers == null || hostAnswers.isEmpty) return const [];
    return hostAnswers[(call - 1).clamp(0, hostAnswers.length - 1).toInt()];
  }
}

final class _FakePinnedTransport implements ClientWebViewPinnedTransport {
  _FakePinnedTransport(this.handler);

  final ClientWebViewTransportResponse Function(Uri uri, String address)
  handler;
  final List<(String, String)> calls = [];

  @override
  Future<ClientWebViewTransportResponse> get(
    Uri uri, {
    required String address,
    required int maxBytes,
  }) async {
    calls.add((uri.toString(), address));
    return handler(uri, address);
  }
}

final class _ThrowingResolver implements ClientWebViewDnsResolver {
  @override
  Future<List<String>> lookup(String host) {
    throw StateError('resolver failed');
  }
}
