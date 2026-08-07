import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/llm_provider/anthropic_messages_provider.dart';
import 'package:ssh_mobile/services/llm_provider/llm_provider_types.dart';
import 'package:ssh_mobile/services/llm_provider/llm_url_utils.dart';

// --- Mocks for HttpClient ---
class MockHttpOverrides extends HttpOverrides {
  final List<List<int>> Function(Uri url) getResponseBytes;

  MockHttpOverrides(this.getResponseBytes);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return MockHttpClient(getResponseBytes);
  }
}

class MockHttpClient implements HttpClient {
  final List<List<int>> Function(Uri url) getResponseBytes;

  MockHttpClient(this.getResponseBytes);

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    return MockHttpClientRequest(getResponseBytes(url));
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return MockHttpClientRequest(getResponseBytes(url));
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return MockHttpClientRequest(getResponseBytes(url));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpClientRequest implements HttpClientRequest {
  final List<List<int>> responseBytes;

  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  int contentLength = 0;

  MockHttpClientRequest(this.responseBytes);

  @override
  void write(Object? obj) {}

  @override
  void add(List<int> data) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async {
    return MockHttpClientResponse(responseBytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _headers = {};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final List<List<int>> responseBytes;

  MockHttpClientResponse(this.responseBytes);

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
    return Stream<List<int>>.fromIterable(responseBytes).listen(
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
  group('AnthropicMessagesProvider tests', () {
    const provider = AnthropicMessagesProvider();

    test(
      'buildAssistantToolCallMessage construct OpenAI-style assistant messages',
      () {
        final msg = provider.buildAssistantToolCallMessage(
          text: 'hello anthropic',
          toolCalls: [
            const LlmProviderToolCall(
              id: 'call_1',
              name: 'client_time',
              argumentsJson: '{"timezone":"UTC"}',
            ),
          ],
          reasoningContent: 'thinking process',
        );

        expect(msg['role'], equals('assistant'));
        expect(msg['content'], equals('hello anthropic'));
        expect(msg['reasoning_content'], equals('thinking process'));
        expect(msg['tool_calls'], isList);
        expect(msg['tool_calls'].length, equals(1));
        expect(msg['tool_calls'][0]['id'], equals('call_1'));
        expect(msg['tool_calls'][0]['type'], equals('function'));
        expect(msg['tool_calls'][0]['function']['name'], equals('client_time'));
        expect(
          msg['tool_calls'][0]['function']['arguments'],
          equals('{"timezone":"UTC"}'),
        );
      },
    );

    test(
      'buildToolResultMessage constructs OpenAI-style tool role messages',
      () {
        final msg = provider.buildToolResultMessage(
          call: const LlmProviderToolCall(
            id: 'call_1',
            name: 'client_time',
            argumentsJson: '{}',
          ),
          result: 'result-data',
        );

        expect(msg['role'], equals('tool'));
        expect(msg['tool_call_id'], equals('call_1'));
        expect(msg['content'], equals('result-data'));
      },
    );

    test(
      'complete converts messages, calls endpoint, and parses usage',
      () async {
        final responseBody = {
          'content': [
            {'type': 'text', 'text': 'hello from anthropic'},
          ],
          'usage': {
            'input_tokens': 20,
            'output_tokens': 12,
            'cache_read_input_tokens': 5,
            'cache_creation_input_tokens': 10,
          },
        };

        final responseBytes = [utf8.encode(jsonEncode(responseBody))];
        HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

        try {
          final result = await provider.complete(
            const LlmProviderRequest(
              baseUrl: 'https://api.anthropic.com',
              apiKey: 'anthropic-key',
              model: 'claude-3',
              messages: [
                {'role': 'system', 'content': 'system rule'},
                {'role': 'user', 'content': 'hello'},
              ],
            ),
          );

          expect(result.text, equals('hello from anthropic'));
          expect(result.usage, isNotNull);
          expect(result.usage!.promptTokens, equals(20));
          expect(result.usage!.completionTokens, equals(12));
          expect(result.usage!.promptCacheHitTokens, equals(5));
          expect(result.usage!.promptCacheMissTokens, equals(10));
        } finally {
          HttpOverrides.global = null;
        }
      },
    );

    test('streamChat streams Anthropic SSE chunks correctly', () async {
      final sseChunks = [
        'data: {"type":"message_start","message":{"usage":{"input_tokens":30,"output_tokens":0,"cache_read_input_tokens":10,"cache_creation_input_tokens":20}}}\n\n',
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi "}}\n\n',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Claude"}}\n\n',
        'data: {"type":"message_delta","usage":{"output_tokens":5}}\n\n',
        'data: {"type":"message_stop"}\n\n',
      ];

      final responseBytes = sseChunks.map((c) => utf8.encode(c)).toList();
      HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

      try {
        final deltaText = <String>[];
        final finalResult = await provider.streamChat(
          LlmProviderRequest(
            baseUrl: 'https://api.anthropic.com',
            apiKey: 'anthropic-key',
            model: 'claude-3',
            messages: [
              {'role': 'user', 'content': 'hello'},
            ],
            onTextDelta: (delta) {
              deltaText.add(delta);
            },
          ),
        );

        expect(finalResult.text, equals('Hi Claude'));
        expect(deltaText, equals(['Hi ', 'Claude']));
        expect(finalResult.usage?.promptTokens, equals(30));
        expect(finalResult.usage?.completionTokens, equals(5));
        expect(finalResult.usage?.promptCacheHitTokens, equals(10));
        expect(finalResult.usage?.promptCacheMissTokens, equals(20));
      } finally {
        HttpOverrides.global = null;
      }
    });

    group('resolveAnthropicUrl tests', () {
      test('resolves standard endpoints correctly', () {
        expect(
          LlmUrlUtils.resolveAnthropicUrl(
            'https://api.anthropic.com',
            '/v1/messages',
          ),
          equals('https://api.anthropic.com/v1/messages'),
        );
        expect(
          LlmUrlUtils.resolveAnthropicUrl(
            'https://api.anthropic.com/',
            '/v1/messages',
          ),
          equals('https://api.anthropic.com/v1/messages'),
        );
        expect(
          LlmUrlUtils.resolveAnthropicUrl(
            'https://api.anthropic.com/v1',
            '/v1/messages',
          ),
          equals('https://api.anthropic.com/v1/messages'),
        );
        expect(
          LlmUrlUtils.resolveAnthropicUrl(
            'https://api.anthropic.com/v1/',
            '/v1/messages',
          ),
          equals('https://api.anthropic.com/v1/messages'),
        );
        expect(
          LlmUrlUtils.resolveAnthropicUrl(
            'https://api.anthropic.com/v1/messages',
            '/v1/messages',
          ),
          equals('https://api.anthropic.com/v1/messages'),
        );
        expect(
          LlmUrlUtils.resolveAnthropicUrl(
            'https://api.anthropic.com/v1/messages',
            '/v1/models',
          ),
          equals('https://api.anthropic.com/v1/models'),
        );
        expect(
          LlmUrlUtils.resolveAnthropicUrl(
            'https://api.anthropic.com/v1/models',
            '/v1/messages',
          ),
          equals('https://api.anthropic.com/v1/messages'),
        );
      });
    });
  });
}
