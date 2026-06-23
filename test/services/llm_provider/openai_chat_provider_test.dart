import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/llm_provider/openai_chat_provider.dart';
import 'package:ssh_mobile/services/llm_provider/llm_provider_types.dart';

// --- Mocks for HttpClient ---
class MockHttpOverrides extends HttpOverrides {
  final List<List<int>> Function(Uri url) getResponseBytes;
  final int Function(Uri url)? getResponseStatusCode;

  MockHttpOverrides(this.getResponseBytes, {this.getResponseStatusCode});

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return MockHttpClient(getResponseBytes, getResponseStatusCode: getResponseStatusCode);
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
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  Future<HttpClientResponse> close() async {
    return MockHttpClientResponse(responseBytes, statusCode: statusCode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final List<List<int>> responseBytes;
  @override
  final int statusCode;

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('OpenAiChatProvider tests', () {
    const provider = OpenAiChatProvider();

    test('buildAssistantToolCallMessage construct OpenAI assistant messages', () {
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
    });

    test('buildToolResultMessage constructs OpenAI tool role messages', () {
      final msg = provider.buildToolResultMessage(
        call: const LlmProviderToolCall(
          id: 'call_123',
          name: 'client_time',
          argumentsJson: '{}',
        ),
        result: '2026-06-22',
      );

      expect(msg['role'], equals('tool'));
      expect(msg['tool_call_id'], equals('call_123'));
      expect(msg['content'], equals('2026-06-22'));
    });

    test('complete gets response and parses prompt tokens', () async {
      final responseBody = {
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': 'hello standard content',
            }
          }
        ],
        'usage': {
          'prompt_tokens': 15,
          'completion_tokens': 10,
          'total_tokens': 25,
        }
      };

      final responseBytes = [utf8.encode(jsonEncode(responseBody))];
      HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

      try {
        final result = await provider.complete(const LlmProviderRequest(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'test-key',
          model: 'gpt-4',
          messages: [
            {'role': 'user', 'content': 'hi'}
          ],
        ));

        expect(result.text, equals('hello standard content'));
        expect(result.usage, isNotNull);
        expect(result.usage!.promptTokens, equals(15));
        expect(result.usage!.completionTokens, equals(10));
        expect(result.usage!.totalTokens, equals(25));
      } finally {
        HttpOverrides.global = null;
      }
    });

    test('streamChat streams SSE chunks correctly', () async {
      final sseChunks = [
        'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n',
        'data: {"choices":[{"delta":{"reasoning_content":"think"}}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"f1","arguments":"{}"}}]}}]}\n\n',
        'data: {"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\n\n',
        'data: [DONE]\n\n',
      ];

      final responseBytes = sseChunks.map((c) => utf8.encode(c)).toList();
      HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

      try {
        final deltaText = <String>[];
        final finalResult = await provider.streamChat(LlmProviderRequest(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'test-key',
          model: 'gpt-4',
          messages: [
            {'role': 'user', 'content': 'hi'}
          ],
          onTextDelta: (delta) {
            deltaText.add(delta);
          },
        ));

        expect(finalResult.text, equals('Hello'));
        expect(deltaText, equals(['Hello']));
        expect(finalResult.reasoningContent, equals('think'));
        expect(finalResult.toolCalls.length, equals(1));
        expect(finalResult.toolCalls[0].id, equals('c1'));
        expect(finalResult.toolCalls[0].name, equals('f1'));
        expect(finalResult.usage?.promptTokens, equals(10));
      } finally {
        HttpOverrides.global = null;
      }
    });

    test('complete disables reasoning parameters on unsupported error fallback', () async {
      var requestCount = 0;
      HttpOverrides.global = MockHttpOverrides(
        (url) {
          if (requestCount == 1) {
            return [utf8.encode('{"error":"does not support reasoning_effort"}')];
          } else {
            return [utf8.encode(jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'fallback success',
                  }
                }
              ]
            }))];
          }
        },
        getResponseStatusCode: (url) {
          requestCount++;
          if (requestCount == 1) {
            return 400;
          }
          return 200;
        },
      );

      try {
        final result = await provider.complete(const LlmProviderRequest(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'test-key',
          model: 'o1-mini',
          openAiReasoningEffort: 'low',
          messages: [
            {'role': 'user', 'content': 'hi'}
          ],
        ));

        expect(result.text, equals('fallback success'));
        expect(requestCount, equals(2));
      } finally {
        HttpOverrides.global = null;
      }
    });

    test('streamChat disables reasoning parameters on unsupported error fallback', () async {
      var requestCount = 0;
      HttpOverrides.global = MockHttpOverrides(
        (url) {
          if (requestCount == 1) {
            return [utf8.encode('{"error":"unsupported parameter thinking"}')];
          } else {
            return [utf8.encode('data: {"choices":[{"delta":{"content":"stream success"}}]}\n\ndata: [DONE]\n\n')];
          }
        },
        getResponseStatusCode: (url) {
          requestCount++;
          if (requestCount == 1) {
            return 400;
          }
          return 200;
        },
      );

      try {
        final result = await provider.streamChat(LlmProviderRequest(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'test-key',
          model: 'deepseek-reasoner',
          deepSeekThinkingEnabled: true,
          messages: [
            {'role': 'user', 'content': 'hi'}
          ],
        ));

        expect(result.text, equals('stream success'));
        expect(requestCount, equals(2));
      } finally {
        HttpOverrides.global = null;
      }
    });
  
    test('fetchModels parses data objects with id and raw strings', () async {
      final responseBody = {
        'data': [
          {'id': 'gpt-4'},
          'claude-3',
          {'id': '  gpt-3.5-turbo  '},
          '',
          'deepseek-chat',
        ]
      };
      final responseBytes = [utf8.encode(jsonEncode(responseBody))];
      HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

      try {
        final result = await provider.fetchModels(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'test-key',
        );

        expect(result, equals(['claude-3', 'deepseek-chat', 'gpt-3.5-turbo', 'gpt-4']));
      } finally {
        HttpOverrides.global = null;
      }
    });

    test('streamChat handles [DONE] line by breaking early', () async {
      final sseChunks = [
        'data: {"choices":[{"delta":{"content":"Part 1"}}]}\n\n',
        'data: [DONE]\n\n',
        'data: {"choices":[{"delta":{"content":"Part 2"}}]}\n\n',
      ];

      final responseBytes = sseChunks.map((c) => utf8.encode(c)).toList();
      HttpOverrides.global = MockHttpOverrides((url) => responseBytes);

      try {
        final deltaText = <String>[];
        final finalResult = await provider.streamChat(LlmProviderRequest(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'test-key',
          model: 'gpt-4',
          messages: [
            {'role': 'user', 'content': 'hi'}
          ],
          onTextDelta: (delta) {
            deltaText.add(delta);
          },
        ));

        expect(finalResult.text, equals('Part 1'));
        expect(deltaText, equals(['Part 1']));
      } finally {
        HttpOverrides.global = null;
      }
    });
  });
}