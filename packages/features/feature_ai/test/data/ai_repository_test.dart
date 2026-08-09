// AI 数据库与 Repository 的持久化契约测试。
//
// 这些测试属于 feature_ai，因为 ai.db 的表、DAO 和加密边界已由 AI
// Module 独立持有；外部测试不再越过模块边界访问 AI 表。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:feature_ai/feature_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AiDatabase database;
  late DriftAiRepository repository;
  late _TestTextProtection protection;

  setUp(() {
    database = AiDatabase.forTesting(NativeDatabase.memory());
    protection = _TestTextProtection();
    repository = DriftAiRepository(database, protection);
  });

  tearDown(() => database.dispose());

  test('AI database opens independently from shared app storage', () async {
    final result = await database.customSelect('SELECT 1 AS value').getSingle();

    expect(result.read<int>('value'), 1);
  });

  test('chat DAO keeps paged summaries and ordered messages', () async {
    final base = DateTime.utc(2026, 6, 21, 11);
    for (var index = 0; index < 3; index++) {
      final created = base.add(Duration(minutes: index));
      await repository.saveChat(_chatRecord(index, created));
    }

    final summaries = await database.aiChatDao.loadChatSummaries(
      limit: 2,
      offset: 1,
    );
    expect(summaries.map((chat) => chat.id).toList(), ['chat-1', 'chat-0']);

    final messages = await database.aiChatDao.loadMessagesForChat('chat-1');
    expect(messages.map((message) => message.role).toList(), [
      'user',
      'assistant',
    ]);
  });

  test('run metrics keep the newest 200 records', () async {
    final base = DateTime.utc(2026, 6, 21);
    for (var index = 0; index < 205; index++) {
      await repository.saveRunMetrics(
        AgentRunMetrics(
          id: 'metric-$index',
          startedAt: base.add(Duration(minutes: index)),
          finishedAt: base.add(Duration(minutes: index, seconds: 10)),
          model: 'model-${index % 2}',
          promptTokens: index,
          completionTokens: index + 1,
          totalTokens: index + 2,
          elapsedMs: 10,
        ),
      );
    }

    final metrics = await repository.loadRunMetrics();
    expect(metrics, hasLength(200));
    expect(metrics.first.id, 'metric-204');
    expect(metrics.last.id, 'metric-5');
  });

  test('repository encrypts AI chat fields before writing them', () async {
    const secret = 'SECRET_AI_MARKER_20260621';
    final now = DateTime.utc(2026, 6, 21, 3);
    final chat = AiChatRecord(
      id: 'chat-secret',
      title: 'Secret chat',
      model: 'model-a',
      messages: [
        AiChatMessageRecord(
          role: 'assistant',
          text: 'message $secret',
          contextText: 'context $secret',
          attachments: [
            AiChatAttachment(
              fileName: 'secret.txt',
              mimeType: 'text/plain',
              sizeBytes: secret.length,
              dataBase64: secret,
            ),
          ],
          traces: [
            AiMessageTrace(
              id: 'trace-secret',
              kind: 'tool',
              title: 'Trace',
              content: 'trace $secret',
              createdAt: now,
            ),
          ],
          todoSteps: const [
            AiTodoStep(
              id: 'task-secret',
              name: 'Task',
              command: 'echo secret',
              description: 'Task description',
              stdout: 'stdout SECRET_AI_MARKER_20260621',
              stderr: 'stderr SECRET_AI_MARKER_20260621',
            ),
          ],
          createdAt: now,
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );

    await repository.saveChat(chat);

    final raw = await database
        .customSelect(
          'SELECT text, context_text, attachments_json, traces_json, '
          'todo_steps_json FROM ai_chat_messages',
        )
        .getSingle();
    expect(raw.read<String>('text'), isNot(contains(secret)));
    expect(raw.read<String>('context_text'), isNot(contains(secret)));
    expect(raw.read<String>('attachments_json'), isNot(contains(secret)));
    expect(raw.read<String>('traces_json'), isNot(contains(secret)));
    expect(raw.read<String>('todo_steps_json'), isNot(contains(secret)));

    final loaded = (await repository.loadChats()).single.messages.single;
    expect(loaded.text, contains(secret));
    expect(loaded.contextText, contains(secret));
    expect(loaded.attachments.single.dataBase64, secret);
    expect(loaded.traces.single.content, contains(secret));
    expect(loaded.todoSteps.single.stdout, contains(secret));
    expect(loaded.todoSteps.single.stderr, contains(secret));
    expect(protection.encryptCalls, greaterThan(0));
    expect(protection.decryptCalls, greaterThan(0));
  });
}

/// 提供可观察的测试加密边界，验证 Repository 不会把敏感正文直接写入 Drift。
final class _TestTextProtection implements AiTextProtectionPort {
  int encryptCalls = 0;
  int decryptCalls = 0;

  @override
  Future<String> encrypt(String plainText) async {
    encryptCalls++;
    return 'encrypted:${base64Encode(utf8.encode(plainText))}';
  }

  @override
  Future<String> decrypt(String storedText) async {
    decryptCalls++;
    if (!storedText.startsWith('encrypted:')) return storedText;
    return utf8.decode(base64Decode(storedText.substring('encrypted:'.length)));
  }
}

/// 创建含有两个时间有序消息的聊天记录，复用真实 Repository 写入路径。
AiChatRecord _chatRecord(int index, DateTime created) {
  return AiChatRecord(
    id: 'chat-$index',
    title: 'Chat $index',
    model: 'model-a',
    messages: [
      AiChatMessageRecord(
        role: 'assistant',
        text: 'second $index',
        createdAt: created.add(const Duration(seconds: 2)),
      ),
      AiChatMessageRecord(
        role: 'user',
        text: 'first $index',
        createdAt: created.add(const Duration(seconds: 1)),
      ),
    ],
    createdAt: created,
    updatedAt: created,
  );
}
