import 'dart:convert';

import 'package:feature_ai/ai_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allows a serialized request exactly at the byte limit', () {
    final request = <String, dynamic>{
      'model': 'test-model',
      'messages': [
        {'role': 'user', 'content': 'hello'},
      ],
    };
    final expected = jsonEncode(request);
    final limit = utf8.encode(expected).length;

    expect(encodeBoundedJsonRequest(request, maxBytes: limit), expected);
  });

  test('rejects a request one UTF-8 byte above the limit', () {
    final request = <String, dynamic>{'content': '中文😀'};
    final expected = jsonEncode(request);
    final limit = utf8.encode(expected).length - 1;

    expect(
      () => encodeBoundedJsonRequest(request, maxBytes: limit),
      throwsA(isA<LlmRequestPayloadTooLargeException>()),
    );
  });

  test('counts JSON escaping, not only the source string length', () {
    final content = List.filled(64, '"\\').join();
    final request = <String, dynamic>{
      'messages': [
        {'role': 'user', 'content': content},
      ],
    };
    final sourceBytes = utf8.encode(content).length;
    final serializedBytes = utf8.encode(jsonEncode(request)).length;

    expect(serializedBytes, greaterThan(sourceBytes));
    expect(
      () => encodeBoundedJsonRequest(request, maxBytes: serializedBytes - 1),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects context, history, tools, and image data as one body', () {
    final currentTurn = 'ok';
    final request = <String, dynamic>{
      'model': 'test-model',
      'messages': [
        {'role': 'system', 'content': 'system context'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': currentTurn},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,${'A' * 256}'},
            },
          ],
        },
        {'role': 'assistant', 'content': 'history ${'h' * 256}'},
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'test_tool',
            'description': 'tool schema ${'t' * 256}',
            'parameters': {'type': 'object'},
          },
        },
      ],
    };
    final turnBytes = utf8.encode(currentTurn).length;
    final serializedBytes = utf8.encode(jsonEncode(request)).length;

    expect(turnBytes, lessThan(serializedBytes));
    expect(
      () => encodeBoundedJsonRequest(request, maxBytes: serializedBytes - 1),
      throwsA(isA<LlmRequestPayloadTooLargeException>()),
    );
  });
}
