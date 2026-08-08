import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/feature_ai.dart'
    show
        AiApprovedPlanRef,
        AiChatAttachment,
        AiChatMessageRecord,
        AiChatRecord,
        AiMessageTrace,
        AiTodoStep,
        AiUploadSizeLimit,
        PlanModeExitActor,
        approvedPlanMessageForChat,
        canExitPlanMode,
        latestAssistantMessageForChat;
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
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
    final result = upsertAiChatRecordsByUpdatedAt([
      chat('old', 1),
      chat('older', 0),
    ], chat('new', 2));

    expect(result.map((item) => item.id), ['new', 'old', 'older']);
  });

  test(
    'upsertAiChatRecordsByUpdatedAt replaces existing record and limits',
    () {
      final result = upsertAiChatRecordsByUpdatedAt(
        [chat('a', 3), chat('b', 2), chat('c', 1)],
        chat('b', 4),
        limit: 2,
      );

      expect(result.map((item) => item.id), ['b', 'a']);
    },
  );

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
    },
  );

  test('AiUploadSizeLimit.normalize clamps and defaults correctly', () {
    // Test default limits when null is passed
    expect(
      AiUploadSizeLimit.normalizeImage(null),
      AiUploadSizeLimit.defaultImageSizeBytes,
    );
    expect(
      AiUploadSizeLimit.normalizeFile(null),
      AiUploadSizeLimit.defaultFileSizeBytes,
    );

    // Test values inside the allowed ranges
    expect(AiUploadSizeLimit.normalizeImage(2 * 1024 * 1024), 2 * 1024 * 1024);
    expect(AiUploadSizeLimit.normalizeFile(20 * 1024 * 1024), 20 * 1024 * 1024);

    // Test values below the minimum range (clamp to first value)
    expect(
      AiUploadSizeLimit.normalizeImage(0),
      AiUploadSizeLimit.imageValues.first,
    );
    expect(
      AiUploadSizeLimit.normalizeImage(-100),
      AiUploadSizeLimit.imageValues.first,
    );
    expect(
      AiUploadSizeLimit.normalizeFile(0),
      AiUploadSizeLimit.fileValues.first,
    );
    expect(
      AiUploadSizeLimit.normalizeFile(-500),
      AiUploadSizeLimit.fileValues.first,
    );

    // Test values above the maximum range (clamp to last value)
    expect(
      AiUploadSizeLimit.normalizeImage(100 * 1024 * 1024),
      AiUploadSizeLimit.imageValues.last,
    );
    expect(
      AiUploadSizeLimit.normalizeFile(500 * 1024 * 1024),
      AiUploadSizeLimit.fileValues.last,
    );

    // Test label helper
    expect(AiUploadSizeLimit.label(5 * 1024 * 1024), '5 MB');
    expect(AiUploadSizeLimit.label(512 * 1024), '512 KB');
  });

  group('AiChatRecord serialization and planMode', () {
    test('round-trips planMode in toJson and fromJson', () {
      final time = DateTime.utc(2026, 1, 1, 12, 0);
      final approvedPlan = AiApprovedPlanRef(
        assistantCreatedAt: time,
        approvedAt: time.add(const Duration(minutes: 5)),
      );
      final record = AiChatRecord(
        id: 'chat-test',
        title: 'Plan Chat',
        model: 'deepseek-v4-flash',
        messages: const [],
        createdAt: time,
        updatedAt: time,
        planMode: true,
        approvedPlan: approvedPlan,
      );

      final json = record.toJson();
      expect(json['planMode'], isTrue);
      expect(json['approvedPlan'], isNotNull);

      final decoded = AiChatRecord.fromJson(json);
      expect(decoded.planMode, isTrue);
      expect(decoded.title, 'Plan Chat');
      expect(
        decoded.approvedPlan?.assistantCreatedAt,
        approvedPlan.assistantCreatedAt,
      );
      expect(decoded.approvedPlan?.approvedAt, approvedPlan.approvedAt);
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
      expect(decoded.approvedPlan, isNull);
    });

    test('approved plan helpers resolve the referenced assistant message', () {
      final base = DateTime.utc(2026, 1, 1, 12, 0);
      final planTime = base.add(const Duration(minutes: 1));
      final executionApprovalTime = base.add(const Duration(minutes: 2));
      final planStep = AiTodoStep(
        id: 'task-1',
        name: 'Check nginx',
        command: 'systemctl status nginx',
        description: 'Verify the service is healthy.',
      );
      final chat = AiChatRecord(
        id: 'chat-approved',
        title: 'Approved',
        model: 'model',
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'Old reply',
            createdAt: base,
          ),
          AiChatMessageRecord(
            role: 'assistant',
            text: 'Plan',
            createdAt: planTime,
            todoSteps: [planStep],
          ),
        ],
        createdAt: base,
        updatedAt: executionApprovalTime,
        approvedPlan: AiApprovedPlanRef(
          assistantCreatedAt: planTime,
          approvedAt: executionApprovalTime,
        ),
      );

      expect(latestAssistantMessageForChat(chat)?.createdAt, planTime);
      expect(approvedPlanMessageForChat(chat)?.todoSteps.single.id, 'task-1');
    });

    test(
      'canExitPlanMode only accepts persisted todoSteps on the latest assistant message',
      () {
        final base = DateTime.utc(2026, 1, 1, 12, 0);
        final oldPlan = AiChatMessageRecord(
          role: 'assistant',
          text: 'Old plan',
          createdAt: base,
          todoSteps: const [
            AiTodoStep(
              id: 'task-old',
              name: 'Old',
              command: 'echo old',
              description: 'old',
            ),
          ],
        );
        final latestWithoutSteps = AiChatMessageRecord(
          role: 'assistant',
          text: 'Broken plan',
          createdAt: base.add(const Duration(minutes: 1)),
        );

        final blockedChat = AiChatRecord(
          id: 'chat-blocked',
          title: 'Blocked',
          model: 'model',
          messages: [oldPlan, latestWithoutSteps],
          createdAt: base,
          updatedAt: base.add(const Duration(minutes: 1)),
          planMode: true,
        );
        expect(canExitPlanMode(blockedChat), isFalse);

        final allowedChat = blockedChat.copyWith(
          messages: [
            oldPlan,
            latestWithoutSteps.copyWith(
              todoSteps: const [
                AiTodoStep(
                  id: 'task-new',
                  name: 'New',
                  command: 'echo new',
                  description: 'new',
                ),
              ],
            ),
          ],
        );
        expect(canExitPlanMode(allowedChat), isTrue);
      },
    );

    test('canExitPlanMode respects PlanModeExitActor settings', () {
      final base = DateTime.utc(2026, 1, 1, 12, 0);
      final blockedChat = AiChatRecord(
        id: 'chat-blocked',
        title: 'Blocked',
        model: 'model',
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'No steps',
            createdAt: base,
          ),
        ],
        createdAt: base,
        updatedAt: base,
        planMode: true,
      );

      expect(
        canExitPlanMode(blockedChat, actor: PlanModeExitActor.llmTool),
        isFalse,
      );
      expect(
        canExitPlanMode(blockedChat, actor: PlanModeExitActor.userUi),
        isTrue,
      );
    });
  });

  group('AiTodoStep and todoSteps serialization', () {
    test('round-trips AiTodoStep and todoSteps correctly', () {
      final time = DateTime.utc(2026, 1, 1, 12, 0);
      final step = AiTodoStep(
        id: 'todo-1',
        name: 'Check Server Status',
        command: 'systemctl status nginx',
        description: 'Verify service is active',
        status: StepStatus.success,
        stdout: 'Active: active (running)',
        stderr: '',
        exitCode: 0,
      );

      final message = AiChatMessageRecord(
        role: 'assistant',
        text: 'This is a plan',
        createdAt: time,
        todoSteps: [step],
      );

      final json = message.toJson();
      expect(json['todoSteps'], isNotNull);
      final stepsJson = json['todoSteps'] as List;
      expect(stepsJson.length, 1);
      expect(stepsJson[0]['status'], 'success');

      final decoded = AiChatMessageRecord.fromJson(json);
      expect(decoded.todoSteps.length, 1);
      final decodedStep = decoded.todoSteps[0];
      expect(decodedStep.id, 'todo-1');
      expect(decodedStep.status, StepStatus.success);
      expect(decodedStep.stdout, 'Active: active (running)');
      expect(decodedStep.exitCode, 0);
    });

    test(
      'backward compatibility: defaults todoSteps to empty list when absent',
      () {
        final time = DateTime.utc(2026, 1, 1, 12, 0);
        final oldJson = {
          'role': 'assistant',
          'text': 'Hello world',
          'createdAt': time.toIso8601String(),
        };

        final decoded = AiChatMessageRecord.fromJson(oldJson);
        expect(decoded.todoSteps, isEmpty);
      },
    );
  });
}
