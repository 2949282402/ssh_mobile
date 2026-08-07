import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/services/plan_approval_eligibility.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 13, 12);

  AiChatMessageRecord planMessage({
    StepStatus status = StepStatus.pending,
    DateTime? created,
  }) {
    return AiChatMessageRecord(
      role: 'assistant',
      text: 'Plan',
      createdAt: created ?? createdAt,
      todoSteps: [
        AiTodoStep(
          id: 'step-1',
          name: 'Inspect service',
          command: 'systemctl status nginx',
          description: 'Read status',
          status: status,
        ),
      ],
    );
  }

  AiChatRecord chat({
    bool planMode = false,
    AiApprovedPlanRef? approvedPlan,
    List<AiChatMessageRecord>? messages,
  }) {
    return AiChatRecord(
      id: 'chat-1',
      title: 'Chat',
      model: 'model',
      createdAt: createdAt,
      updatedAt: createdAt,
      planMode: planMode,
      approvedPlan: approvedPlan,
      messages: messages ?? [planMessage()],
    );
  }

  test('returns only the latest fully pending execution-ready plan', () {
    final eligible = chat();
    expect(approvablePlanMessageForChat(eligible), eligible.messages.single);

    expect(
      approvablePlanMessageForChat(chat(planMode: true)),
      isNull,
      reason: 'a partial Plan Mode response is not ready',
    );
    expect(
      approvablePlanMessageForChat(
        chat(
          approvedPlan: AiApprovedPlanRef(
            assistantCreatedAt: createdAt,
            approvedAt: createdAt,
          ),
        ),
      ),
      isNull,
      reason: 'an approved plan cannot be approved twice',
    );
    expect(
      approvablePlanMessageForChat(
        chat(messages: [planMessage(status: StepStatus.running)]),
      ),
      isNull,
      reason: 'execution already started',
    );
    expect(
      approvablePlanMessageForChat(
        chat(
          messages: [
            planMessage(),
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Newer non-plan response',
              createdAt: createdAt.add(const Duration(seconds: 1)),
            ),
          ],
        ),
      ),
      isNull,
      reason: 'a stale assistant plan is not actionable',
    );
  });
}
