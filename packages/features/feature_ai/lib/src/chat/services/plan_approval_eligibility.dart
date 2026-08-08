import 'package:feature_playbook/feature_playbook.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';

AiChatMessageRecord? approvablePlanMessageForChat(AiChatRecord chat) {
  if (chat.planMode || chat.approvedPlan != null) return null;
  final latestAssistant = latestAssistantMessageForChat(chat);
  if (latestAssistant == null ||
      latestAssistant.todoSteps.isEmpty ||
      !latestAssistant.todoSteps.every(
        (step) => step.status == StepStatus.pending,
      )) {
    return null;
  }
  return latestAssistant;
}
