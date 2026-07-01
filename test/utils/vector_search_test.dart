import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/utils/vector_search_utils.dart';

// --- Mocks for HttpClient ---
class MockHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return MockHttpClient();
  }
}

class MockHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    return MockHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return MockHttpClientRequest();
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpClientRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  void write(Object? obj) {}

  @override
  Future<HttpClientResponse> close() async {
    return MockHttpClientResponse();
  }

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _headers = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  int get contentLength => -1;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => '';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  List<Cookie> get cookies => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    // 模拟阿里云通义千问 Embedding 返回 of JSON 格式
    final fakeResponse = {
      'output': {
        'embeddings': [
          {
            'embedding': [0.1, 0.2, -0.3],
            'text_index': 0
          },
          {
            'embedding': [-0.5, 0.6, 0.0],
            'text_index': 1
          }
        ]
      },
      'usage': {'total_tokens': 15}
    };
    final bytes = utf8.encode(jsonEncode(fakeResponse));
    return Stream<List<int>>.fromIterable([bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('VectorMath Tests', () {
    test('Calculates dot product of normalized vectors correctly', () {
      final a = [1.0, 0.0, 0.0];
      final b = [0.0, 1.0, 0.0];
      final c = [0.6, 0.8, 0.0];

      expect(VectorMath.dotProduct(a, b), 0.0);
      expect(VectorMath.dotProduct(a, c), closeTo(0.6, 0.0001));
      expect(VectorMath.dotProduct(b, c), closeTo(0.8, 0.0001));
    });
  });

  group('RrfMerger Tests', () {
    test('Fuses ranked lists by position correctly', () {
      // Doc lists
      final bm25 = ['doc-A', 'doc-B', 'doc-C'];
      final vector = ['doc-C', 'doc-A', 'doc-D'];

      final fused = RrfMerger.merge(bm25Rank: bm25, vectorRank: vector);

      expect(fused.first, 'doc-A'); // High score
      expect(fused[1], 'doc-C'); // Next high score
      expect(fused.length, 4);
    });
  });

  group('AliyunEmbeddingClient Tests', () {
    setUp(() {
      HttpOverrides.global = MockHttpOverrides();
    });

    tearDown(() {
      HttpOverrides.global = null;
    });

    test('Sends request and decodes embedding vectors correctly', () async {
      final client = AliyunEmbeddingClient(apiKey: 'fake-key');
      final result = await client.getEmbeddings(['hello', 'world']);

      expect(result.length, 2);
      expect(result[0], [0.1, 0.2, -0.3]);
      expect(result[1], [-0.5, 0.6, 0.0]);
    });
  });
}
