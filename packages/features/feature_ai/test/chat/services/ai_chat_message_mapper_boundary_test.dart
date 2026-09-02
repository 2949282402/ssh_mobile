import 'dart:convert';

import 'package:feature_ai/ai_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bounds oversized ASCII text and keeps the truncation marker', () {
    final text = 'a' * (AiAttachmentBudget.maxTurnPayloadBytes + 1);
    final result = _mappedText(text);

    expect(result, endsWith('[Message text truncated to request budget]'));
    expect(
      utf8.encode(result).length,
      lessThanOrEqualTo(AiAttachmentBudget.maxTurnPayloadBytes),
    );
  });

  test('bounds oversized Chinese text without cutting UTF-8 characters', () {
    final text = '中' * ((AiAttachmentBudget.maxTurnPayloadBytes ~/ 3) + 1);
    final result = _mappedText(text);

    expect(result, contains('[Message text truncated to request budget]'));
    expect(utf8.decode(utf8.encode(result)), result);
    expect(
      utf8.encode(result).length,
      lessThanOrEqualTo(AiAttachmentBudget.maxTurnPayloadBytes),
    );
  });

  test('bounds oversized emoji text without splitting surrogate pairs', () {
    final text = '😀' * ((AiAttachmentBudget.maxTurnPayloadBytes ~/ 4) + 1);
    final result = _mappedText(text);

    expect(result, contains('[Message text truncated to request budget]'));
    expect(utf8.decode(utf8.encode(result)), result);
    expect(
      utf8.encode(result).length,
      lessThanOrEqualTo(AiAttachmentBudget.maxTurnPayloadBytes),
    );
  });

  test('does not truncate text exactly at the turn byte boundary', () {
    final text = 'a' * AiAttachmentBudget.maxTurnPayloadBytes;

    expect(_mappedText(text), text);
  });
}

String _mappedText(String text) {
  final message = AiChatMessageRecord(
    role: 'user',
    text: text,
    createdAt: DateTime.utc(2026, 1, 1),
  );
  final mapped = const AiChatMessageMapper(
    contextBuilder: AiChatContextBuilder(),
  ).messagesForRequest([message]);
  return mapped.single['content'] as String;
}
