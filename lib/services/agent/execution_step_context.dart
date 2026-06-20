import '../../features/playbook/models/playbook.dart';

class ExecutionStepContext {
  final String chatId;
  final String assistantMessageId;
  final String taskId;
  final int stepIndex;
  final int totalSteps;
  final String stepName;
  final String? command;
  final String? connectionId;
  final StepStatus status;
  final bool isBlockedByPreviousFailure;

  const ExecutionStepContext({
    required this.chatId,
    required this.assistantMessageId,
    required this.taskId,
    required this.stepIndex,
    required this.totalSteps,
    required this.stepName,
    required this.command,
    required this.connectionId,
    required this.status,
    required this.isBlockedByPreviousFailure,
  });
}
