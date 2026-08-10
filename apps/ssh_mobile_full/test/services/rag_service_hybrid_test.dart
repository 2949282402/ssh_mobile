import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_utils/test_storage_adapter.dart';

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
    // 模拟通义千问 Embedding API 向量数据 (1024 维，全 0.1 和 0.2 以对应测试)
    final fakeVector = List<double>.generate(
      1024,
      (idx) => idx % 2 == 0 ? 0.01 : -0.01,
    );
    final fakeResponse = {
      'output': {
        'embeddings': [
          {'embedding': fakeVector, 'text_index': 0},
          {'embedding': fakeVector, 'text_index': 1},
        ],
      },
      'usage': {'total_tokens': 10},
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storage;

  setUp(() async {
    HttpOverrides.global = MockHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'ai_aliyun_api_key': 'aliyun-test-key-123',
    });

    storage = TestStorageAdapter();
    await storage.init();
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await storage.shutdown();
    storage.dispose();
  });

  group('TestRagService Hybrid Search Tests', () {
    test(
      'addDocument generates embeddings and retrieve uses RRF fusion',
      () async {
        final service = await createTestRagService(storage);
        addTearDown(service.dispose);
        await service.init();

        // 1. 添加带有阿里云向量的文档
        const text =
            'Use systemctl restart nginx to reboot server. '
            'Use kubectl get pods to view pods.';
        final metadata = await service.addDocument(
          name: 'test_ops.txt',
          bytes: text.codeUnits,
          mimeType: 'text/plain',
        );

        expect(metadata.chunkCount > 0, true);

        // 2. 向量检索模式验证
        final vectorChunks = await service.retrieve(
          'reboot nginx',
          searchMode: 'vector',
        );
        expect(vectorChunks.isNotEmpty, true);
        expect(
          vectorChunks.first.text.contains('systemctl restart nginx'),
          true,
        );

        // 3. 混合检索模式验证
        final hybridChunks = await service.retrieve(
          'kubectl get pods',
          searchMode: 'hybrid',
        );
        expect(hybridChunks.isNotEmpty, true);
        expect(hybridChunks.first.text.contains('kubectl get'), true);
      },
    );
  });
}
