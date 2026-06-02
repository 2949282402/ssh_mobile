import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

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
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _headers = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    // 模拟通义千问 Embedding API 向量数据 (1024 维，全 0.1 和 0.2 以对应测试)
    final fakeVector =
        List<double>.generate(1024, (idx) => idx % 2 == 0 ? 0.01 : -0.01);
    final fakeResponse = {
      'output': {
        'embeddings': [
          {'embedding': fakeVector, 'text_index': 0},
          {'embedding': fakeVector, 'text_index': 1}
        ]
      },
      'usage': {'total_tokens': 10}
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');

  late StorageService storage;

  setUp(() async {
    HttpOverrides.global = MockHttpOverrides();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (MethodCall methodCall) async {
      return '.';
    });

    SharedPreferences.setMockInitialValues({
      'rag_search_mode': 'hybrid',
    });
    FlutterSecureStorage.setMockInitialValues({
      'ai_aliyun_api_key': 'aliyun-test-key-123',
    });

    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    HttpOverrides.global = null;
    storage.dispose();

    final file = File('rag_database.json');
    if (await file.exists()) {
      await file.delete();
    }
  });

  group('RagService Hybrid Search Tests', () {
    test('addDocument generates embeddings and retrieve uses RRF fusion',
        () async {
      final service = RagService(storageService: storage);
      await service.init();

      // 1. 添加带有阿里云向量的文档
      const text = 'Use systemctl restart nginx to reboot server. '
          'Use kubectl get pods to view pods.';
      final metadata = await service.addDocument(
        name: 'test_ops.txt',
        bytes: text.codeUnits,
        mimeType: 'text/plain',
      );

      expect(metadata.chunkCount > 0, true);

      // 2. 向量检索模式验证
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('rag_search_mode', 'vector');

      final vectorChunks = await service.retrieve('reboot nginx');
      expect(vectorChunks.isNotEmpty, true);
      expect(vectorChunks.first.text.contains('systemctl restart nginx'), true);

      // 3. 混合检索模式验证
      await prefs.setString('rag_search_mode', 'hybrid');

      final hybridChunks = await service.retrieve('kubectl get pods');
      expect(hybridChunks.isNotEmpty, true);
      expect(hybridChunks.first.text.contains('kubectl get'), true);
    });
  });
}
