import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_playbook/feature_playbook.dart';

void main() {
  test('persisted plan state wins without discarding streamed content', () {
    final createdAt = DateTime.utc(2026, 7, 13, 10);
    final messageCreatedAt = createdAt.add(
      const Duration(seconds: 1, microseconds: 321),
    );
    final persistedMessageCreatedAt = DateTime.fromMillisecondsSinceEpoch(
      messageCreatedAt.millisecondsSinceEpoch,
      isUtc: true,
    );
    final memoryChat = AiChatRecord(
      id: 'chat-1',
      title: 'Memory title',
      model: 'demo-model',
      messages: [
        AiChatMessageRecord(
          role: 'assistant',
          text: 'streamed answer',
          traces: [
            AiMessageTrace(
              id: 'trace-1',
              kind: 'status',
              title: 'Running',
              content: 'latest trace',
              createdAt: messageCreatedAt,
            ),
          ],
          createdAt: messageCreatedAt,
        ),
      ],
      createdAt: createdAt,
      updatedAt: messageCreatedAt,
      planMode: true,
      approvedPlan: AiApprovedPlanRef(
        assistantCreatedAt: messageCreatedAt,
        approvedAt: messageCreatedAt,
      ),
    );
    final persistedAt = messageCreatedAt.add(const Duration(seconds: 2));
    final persistedChat = memoryChat.copyWith(
      messages: [
        AiChatMessageRecord(
          role: 'assistant',
          text: '',
          createdAt: persistedMessageCreatedAt,
          todoSteps: const [
            AiTodoStep(
              id: 'task-1',
              name: 'Check service',
              command: 'systemctl status nginx',
              description: 'Inspect nginx',
              status: StepStatus.success,
              stdout: 'active',
              exitCode: 0,
            ),
          ],
        ),
      ],
      updatedAt: persistedAt,
      planMode: false,
      clearApprovedPlan: true,
    );

    final reconciled = const AiChatRunStateReconciler().reconcile(
      memoryChat: memoryChat,
      persistedChat: persistedChat,
    );

    expect(reconciled.messages.single.text, 'streamed answer');
    expect(reconciled.messages.single.traces.single.id, 'trace-1');
    expect(
      reconciled.messages.single.todoSteps.single.status,
      StepStatus.success,
    );
    expect(reconciled.messages.single.todoSteps.single.stdout, 'active');
    expect(reconciled.planMode, isFalse);
    expect(reconciled.approvedPlan, isNull);
    expect(reconciled.updatedAt, persistedAt);
  });

  test('different chat ids are never merged', () {
    final now = DateTime.utc(2026, 7, 13);
    final memoryChat = AiChatRecord(
      id: 'memory',
      title: 'Memory',
      model: 'demo-model',
      messages: const [],
      createdAt: now,
      updatedAt: now,
      planMode: true,
    );
    final persistedChat = AiChatRecord(
      id: 'persisted',
      title: 'Persisted',
      model: 'demo-model',
      messages: const [],
      createdAt: now,
      updatedAt: now,
      planMode: false,
    );

    final reconciled = const AiChatRunStateReconciler().reconcile(
      memoryChat: memoryChat,
      persistedChat: persistedChat,
    );

    expect(identical(reconciled, memoryChat), isTrue);
  });
}
