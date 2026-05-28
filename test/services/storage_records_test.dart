import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  AiChatRecord chat(String id, int minute) {
    final time = DateTime.utc(2026, 1, 1, 12, minute);
    return AiChatRecord(
      id: id,
      title: id,
      model: 'model',
      messages: const [],
      createdAt: time,
      updatedAt: time,
    );
  }

  test('upsertAiChatRecordsByUpdatedAt inserts by latest updatedAt', () {
    final result = upsertAiChatRecordsByUpdatedAt(
      [chat('old', 1), chat('older', 0)],
      chat('new', 2),
    );

    expect(result.map((item) => item.id), ['new', 'old', 'older']);
  });

  test('upsertAiChatRecordsByUpdatedAt replaces existing record and limits',
      () {
    final result = upsertAiChatRecordsByUpdatedAt(
      [chat('a', 3), chat('b', 2), chat('c', 1)],
      chat('b', 4),
      limit: 2,
    );

    expect(result.map((item) => item.id), ['b', 'a']);
  });

  test('AiChatMessageRecord round-trips context, traces, and token stats', () {
    final createdAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final trace = AiMessageTrace(
      id: 'trace-1',
      kind: 'tool_result',
      title: 'Tool result',
      content: '{"ok":true}',
      createdAt: createdAt,
    );
    final message = AiChatMessageRecord(
      role: 'assistant',
      text: 'done',
      contextText: 'slim memory',
      traces: [trace],
      createdAt: createdAt,
      promptTokens: 10,
      completionTokens: 5,
      totalTokens: 15,
      elapsedMs: 1234,
      tokenUsageEstimated: false,
      promptCacheHitTokens: 3,
      promptCacheMissTokens: 7,
      reasoningTokens: 2,
    );

    final decoded = AiChatMessageRecord.fromJson(message.toJson());

    expect(decoded.contextText, 'slim memory');
    expect(decoded.traces.single.id, 'trace-1');
    expect(decoded.totalTokens, 15);
    expect(decoded.reasoningTokens, 2);
  });
}
