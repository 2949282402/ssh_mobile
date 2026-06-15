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

  test('AiChatAttachment round-trips toJson and fromJson', () {
    final attachment = AiChatAttachment(
      fileName: 'test.png',
      mimeType: 'image/png',
      sizeBytes: 1024,
      dataBase64: 'dGVzdA==',
    );

    final decoded = AiChatAttachment.fromJson(attachment.toJson());

    expect(decoded.fileName, 'test.png');
    expect(decoded.mimeType, 'image/png');
    expect(decoded.sizeBytes, 1024);
    expect(decoded.dataBase64, 'dGVzdA==');
    expect(decoded.isImage, isTrue);
    expect(decoded.isTextFile, isFalse);
  });

  test(
      'AiChatMessageRecord round-trips attachments and supports backward compatibility',
      () {
    final createdAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final attachment = AiChatAttachment(
      fileName: 'notes.txt',
      mimeType: 'text/plain',
      sizeBytes: 15,
      dataBase64: 'aGVsbG8gd29ybGQ=',
    );
    final message = AiChatMessageRecord(
      role: 'user',
      text: 'hello',
      createdAt: createdAt,
      attachments: [attachment],
    );

    // 1. Verify serialization round-trip with attachments
    final decoded = AiChatMessageRecord.fromJson(message.toJson());
    expect(decoded.attachments.length, 1);
    expect(decoded.attachments[0].fileName, 'notes.txt');
    expect(decoded.attachments[0].isTextFile, isTrue);

    // 2. Verify backward compatibility: old JSON without attachments field
    final oldJson = {
      'role': 'user',
      'text': 'hello legacy',
      'createdAt': createdAt.toIso8601String(),
    };
    final legacyDecoded = AiChatMessageRecord.fromJson(oldJson);
    expect(legacyDecoded.text, 'hello legacy');
    expect(legacyDecoded.attachments, isEmpty);
  });

  test('AiUploadSizeLimit.normalize clamps and defaults correctly', () {
    // Test default limits when null is passed
    expect(AiUploadSizeLimit.normalizeImage(null),
        AiUploadSizeLimit.defaultImageSizeBytes);
    expect(AiUploadSizeLimit.normalizeFile(null),
        AiUploadSizeLimit.defaultFileSizeBytes);

    // Test values inside the allowed ranges
    expect(AiUploadSizeLimit.normalizeImage(2 * 1024 * 1024), 2 * 1024 * 1024);
    expect(AiUploadSizeLimit.normalizeFile(20 * 1024 * 1024), 20 * 1024 * 1024);

    // Test values below the minimum range (clamp to first value)
    expect(AiUploadSizeLimit.normalizeImage(0),
        AiUploadSizeLimit.imageValues.first);
    expect(AiUploadSizeLimit.normalizeImage(-100),
        AiUploadSizeLimit.imageValues.first);
    expect(
        AiUploadSizeLimit.normalizeFile(0), AiUploadSizeLimit.fileValues.first);
    expect(AiUploadSizeLimit.normalizeFile(-500),
        AiUploadSizeLimit.fileValues.first);

    // Test values above the maximum range (clamp to last value)
    expect(AiUploadSizeLimit.normalizeImage(100 * 1024 * 1024),
        AiUploadSizeLimit.imageValues.last);
    expect(AiUploadSizeLimit.normalizeFile(500 * 1024 * 1024),
        AiUploadSizeLimit.fileValues.last);

    // Test label helper
    expect(AiUploadSizeLimit.label(5 * 1024 * 1024), '5 MB');
    expect(AiUploadSizeLimit.label(512 * 1024), '512 KB');
  });

  group('AiChatRecord serialization and planMode', () {
    test('round-trips planMode in toJson and fromJson', () {
      final time = DateTime.utc(2026, 1, 1, 12, 0);
      final record = AiChatRecord(
        id: 'chat-test',
        title: 'Plan Chat',
        model: 'deepseek-v4-flash',
        messages: const [],
        createdAt: time,
        updatedAt: time,
        planMode: true,
      );

      final json = record.toJson();
      expect(json['planMode'], isTrue);

      final decoded = AiChatRecord.fromJson(json);
      expect(decoded.planMode, isTrue);
      expect(decoded.title, 'Plan Chat');
    });

    test('backward compatibility: defaults planMode to false when absent', () {
      final time = DateTime.utc(2026, 1, 1, 12, 0);
      final legacyJson = {
        'id': 'legacy-chat',
        'title': 'Legacy Chat',
        'model': 'deepseek-v4-flash',
        'messages': <Map<String, dynamic>>[],
        'createdAt': time.toIso8601String(),
        'updatedAt': time.toIso8601String(),
      };

      final decoded = AiChatRecord.fromJson(legacyJson);
      expect(decoded.planMode, isFalse);
      expect(decoded.title, 'Legacy Chat');
    });
  });
}
