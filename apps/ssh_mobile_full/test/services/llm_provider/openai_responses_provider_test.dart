import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_llm.dart';

// --- Mocks for HttpClient ---
class MockHttpOverrides extends HttpOverrides {
  final List<List<int>> Function(Uri url) getResponseBytes;
  final int Function(Uri url)? getResponseStatusCode;

  MockHttpOverrides(this.getResponseBytes, {this.getResponseStatusCode});

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return MockHttpClient(
      getResponseBytes,
      getResponseStatusCode: getResponseStatusCode,
    );
  }
}

class MockHttpClient implements HttpClient {
  final List<List<int>> Function(Uri url) getResponseBytes;
  final int Function(Uri url)? getResponseStatusCode;

  MockHttpClient(this.getResponseBytes, {this.getResponseStatusCode});

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final status = getResponseStatusCode?.call(url) ?? 200;
    return MockHttpClientRequest(getResponseBytes(url), statusCode: status);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final status = getResponseStatusCode?.call(url) ?? 200;
    return MockHttpClientRequest(getResponseBytes(url), statusCode: status);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final status = getResponseStatusCode?.call(url) ?? 200;
    return MockHttpClientRequest(getResponseBytes(url), statusCode: status);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpClientRequest implements HttpClientRequest {
  final List<List<int>> responseBytes;
  final int statusCode;

  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  int contentLength = 0;

  MockHttpClientRequest(this.responseBytes, {this.statusCode = 200});

  @override
  void write(Object? obj) {}

  @override
  void add(List<int> data) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async {
    return MockHttpClientResponse(responseBytes, statusCode: statusCode);
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
  @override
  final int statusCode;

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

  MockHttpClientResponse(this.responseBytes, {this.statusCode = 200});

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
  group('OpenAiResponsesProvider tests', () {
    const provider = OpenAiResponsesProvider();

    test(
      'buildAssistantToolCallMessage constructs OpenAI assistant messages',
      () {
        final msg = provider.buildAssistantToolCallMessage(
          text: 'hello',
          toolCalls: [
            const LlmProviderToolCall(
              id: 'call_123',
              name: 'client_time',
              argumentsJson: '{}',
            ),
          ],
          reasoningContent: 'thinking...',
        );

        expect(msg['role'], equals('assistant'));
        expect(msg['content'], equals('hello'));
        expect(msg['reasoning_content'], equals('thinking...'));
        expect(msg['tool_calls'], isList);
        expect(msg['tool_calls'].length, equals(1));
        expect(msg['tool_calls'][0]['id'], equals('call_123'));
        expect(msg['tool_calls'][0]['type'], equals('function'));
        expect(msg['tool_calls'][0]['function']['name'], equals('client_time'));
        expect(msg['tool_calls'][0]['function']['arguments'], equals('{}'));
      },
    );

    test('buildToolResultMessage constructs OpenAI tool role messages', () {
      final msg = provider.buildToolResultMessage(
        call: const LlmProviderToolCall(
          id: 'call_123',
          name: 'client_time',
          argumentsJson: '{}',
        ),
        result: '2026-07-16',
      );

      expect(msg['role'], equals('tool'));
      expect(msg['tool_call_id'], equals('call_123'));
      expect(msg['content'], equals('2026-07-16'));
    });

    test(
      'complete gets responses API format and parses text/usage/tools',
      () async {
        final responseBody = {
          'id': 'resp_123',
          'status': 'completed',
          'output': [
            {
              'id': 'msg_1',
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'hello response content'},
              ],
            },
            {
              'id': 'fc_1',
              'type': 'function_call',
              'name': 'get_weather',
              'arguments': '{"location": "Singapore"}',
            },
          ],
          'usage': {
            'prompt_tokens': 12,
            'completion_tokens': 8,
            'total_tokens': 20,
          },
        };

        final responseBytes = [utf8.encode(jsonEncode(responseBody))];
        HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

        try {
          final result = await provider.complete(
            const LlmProviderRequest(
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'sk-test',
              model: 'gpt-4o',
              messages: [
                {'role': 'user', 'content': 'hi'},
              ],
              tools: [],
              includeTools: true,
              includeUsage: true,
            ),
          );

          expect(result.text, equals('hello response content'));
          expect(result.toolCalls.length, equals(1));
          expect(result.toolCalls[0].id, equals('fc_1'));
          expect(result.toolCalls[0].name, equals('get_weather'));
          expect(
            result.toolCalls[0].argumentsJson,
            equals('{"location": "Singapore"}'),
          );
          expect(result.usage?.promptTokens, equals(12));
          expect(result.usage?.completionTokens, equals(8));
        } finally {
          HttpOverrides.global = null;
        }
      },
    );

    test(
      'streamChat streams events and parses output_text.delta and function_call deltas',
      () async {
        final events = [
          'data: ${jsonEncode({'type': 'response.created'})}\n\n',
          'data: ${jsonEncode({
            'type': 'response.output_item.added',
            'item': {'id': 'fc_stream_1', 'type': 'function_call', 'name': 'search_web'},
          })}\n\n',
          'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'item_id': 'fc_stream_1', 'delta': '{"query": '})}\n\n',
          'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'item_id': 'fc_stream_1', 'delta': '"google"}'})}\n\n',
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': 'streaming '})}\n\n',
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': 'text'})}\n\n',
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'usage': {'prompt_tokens': 30, 'completion_tokens': 15, 'total_tokens': 45},
            },
          })}\n\n',
          'data: [DONE]\n\n',
        ];

        final responseBytes = events.map((e) => utf8.encode(e)).toList();
        HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

        final deltasCollected = <String>[];

        try {
          final result = await provider.streamChat(
            LlmProviderRequest(
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'sk-test',
              model: 'gpt-4o',
              messages: [
                {'role': 'user', 'content': 'stream me'},
              ],
              tools: [],
              includeTools: true,
              includeUsage: true,
              onTextDelta: (text) => deltasCollected.add(text),
            ),
          );

          expect(result.text, equals('streaming text'));
          expect(deltasCollected, equals(['streaming ', 'text']));
          expect(result.toolCalls.length, equals(1));
          expect(result.toolCalls[0].id, equals('fc_stream_1'));
          expect(result.toolCalls[0].name, equals('search_web'));
          expect(
            result.toolCalls[0].argumentsJson,
            equals('{"query": "google"}'),
          );
          expect(result.usage?.promptTokens, equals(30));
          expect(result.usage?.completionTokens, equals(15));
        } finally {
          HttpOverrides.global = null;
        }
      },
    );
  });
}
