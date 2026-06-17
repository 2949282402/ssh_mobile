import '../../features/playbook/models/playbook.dart';
import '../storage_service.dart';

class PlanExecutionValidationResult {
  final bool allowed;
  final String? errorMessage;

  const PlanExecutionValidationResult.allowed() : allowed = true, errorMessage = null;
  const PlanExecutionValidationResult.denied(this.errorMessage) : allowed = false;
}

class PlanExecutionController {
  const PlanExecutionController();

  static AiTodoStep? findCurrentStep(List<AiTodoStep> steps) {
    for (final step in steps) {
      if (step.status == StepStatus.pending || step.status == StepStatus.running) {
        return step;
      }
    }
    return null;
  }

  PlanExecutionValidationResult validateTransition({
    required List<AiTodoStep> steps,
    required String targetTaskId,
    required StepStatus nextStatus,
  }) {
    final targetIndex = steps.indexWhere((s) => s.id == targetTaskId);
    if (targetIndex == -1) {
      return const PlanExecutionValidationResult.denied('Task step not found in the plan.');
    }
    final currentStep = steps[targetIndex];
    final currentStatus = currentStep.status;

    if (currentStatus == nextStatus) {
      return const PlanExecutionValidationResult.allowed();
    }

    // Rule 1: Cannot modify already completed tasks (success, failed, skipped)
    if (currentStatus == StepStatus.success ||
        currentStatus == StepStatus.failed ||
        currentStatus == StepStatus.skipped) {
      return PlanExecutionValidationResult.denied(
        'Invalid transition: completed task "${currentStep.name}" in state '
        '${currentStatus.name} cannot be modified.'
      );
    }

    // Rule 2: Cannot jump states out of order (e.g. pending directly to success)
    if (currentStatus == StepStatus.pending) {
      if (nextStatus != StepStatus.running && nextStatus != StepStatus.skipped) {
        return PlanExecutionValidationResult.denied(
          'Invalid transition: task "${currentStep.name}" must go from pending to running or skipped. '
          'Cannot jump directly from pending to ${nextStatus.name}.'
        );
      }
    } else if (currentStatus == StepStatus.running) {
      if (nextStatus != StepStatus.success &&
          nextStatus != StepStatus.failed &&
          nextStatus != StepStatus.skipped) {
        return PlanExecutionValidationResult.denied(
          'Invalid transition: running task "${currentStep.name}" can only transition to success, failed, or skipped.'
        );
      }
    }

    // Rule 3: Sequenced ordering check for "running" (sequential check)
    if (nextStatus == StepStatus.running) {
      // Check if any other task is currently running
      final runningIndex = steps.indexWhere((s) => s.status == StepStatus.running);
      if (runningIndex != -1 && runningIndex != targetIndex) {
        return PlanExecutionValidationResult.denied(
          'Order violation: cannot start task "${currentStep.name}" because task '
          '"${steps[runningIndex].name}" is currently running. Only one task can run at a time.'
        );
      }

      // Check if all preceding steps are completed
      for (var i = 0; i < targetIndex; i++) {
        final priorStep = steps[i];
        if (priorStep.status != StepStatus.success &&
            priorStep.status != StepStatus.failed &&
            priorStep.status != StepStatus.skipped) {
          return PlanExecutionValidationResult.denied(
            'Order violation: cannot start task "${currentStep.name}" because a preceding task '
            '"${priorStep.name}" is in state ${priorStep.status.name}. Execute tasks in order.'
          );
        }
      }
    }

    // Rule 4: Block run if there are failed tasks before
    if (nextStatus == StepStatus.running) {
      for (var i = 0; i < targetIndex; i++) {
        final priorStep = steps[i];
        if (priorStep.status == StepStatus.failed) {
          return PlanExecutionValidationResult.denied(
            'Plan blocked: cannot execute "${currentStep.name}" because a prior step '
            '"${priorStep.name}" failed. Resolve the failure first.'
          );
        }
      }
    }

    return const PlanExecutionValidationResult.allowed();
  }
}
