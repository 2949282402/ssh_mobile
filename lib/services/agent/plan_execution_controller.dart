import '../../features/playbook/models/playbook.dart';
import '../storage_service.dart';

class PlanExecutionValidationResult {
  final bool allowed;
  final String? errorMessage;
  final String? code;

  const PlanExecutionValidationResult.allowed()
      : allowed = true,
        errorMessage = null,
        code = null;
  const PlanExecutionValidationResult.denied(this.errorMessage, [this.code])
      : allowed = false;
}

class PlanExecutionGateResult {
  final bool allowed;
  final String? reason;
  final AiTodoStep? currentStep;
  final bool requiresTaskUpdateBeforeTool;
  final bool requiresTaskUpdateAfterTool;

  const PlanExecutionGateResult({
    required this.allowed,
    this.reason,
    this.currentStep,
    this.requiresTaskUpdateBeforeTool = false,
    this.requiresTaskUpdateAfterTool = false,
  });
}

enum PlanExecutionPhase {
  none,
  pending,
  running,
  blockedByFailure,
  completed,
}

class PlanExecutionSnapshot {
  final PlanExecutionPhase phase;
  final List<AiTodoStep> steps;
  final int? currentStepIndex;
  final AiTodoStep? currentStep;
  final bool hasFailedStep;
  final bool isCompleted;

  const PlanExecutionSnapshot({
    required this.phase,
    required this.steps,
    required this.currentStepIndex,
    required this.currentStep,
    required this.hasFailedStep,
    required this.isCompleted,
  });
}

class PlanExecutionController {
  const PlanExecutionController();

  bool isMutatingRemoteTool(String toolName, String executionMode) {
    final isClientOrApp = toolName.startsWith('client_') ||
        toolName.startsWith('app_') ||
        toolName == 'web_search';
    if (isClientOrApp) return false;
    return executionMode == 'stateChanging' || toolName == 'run_command';
  }

  PlanExecutionGateResult canRunToolForCurrentStep({
    required List<AiTodoStep> steps,
    required String toolName,
    required String executionMode,
    required Map<String, dynamic> arguments,
  }) {
    if (steps.isEmpty) {
      return const PlanExecutionGateResult(allowed: true);
    }

    if (!isMutatingRemoteTool(toolName, executionMode)) {
      return const PlanExecutionGateResult(allowed: true);
    }

    final snap = snapshot(steps);
    if (snap.isCompleted) {
      return const PlanExecutionGateResult(
        allowed: false,
        reason: 'plan_completed',
      );
    }

    if (snap.phase == PlanExecutionPhase.blockedByFailure) {
      return PlanExecutionGateResult(
        allowed: false,
        reason: 'previous_step_failed',
        currentStep: snap.currentStep,
      );
    }

    final currentStep = snap.currentStep;
    if (currentStep == null) {
      return const PlanExecutionGateResult(
        allowed: false,
        reason: 'no_active_step',
      );
    }

    if (currentStep.status == StepStatus.pending) {
      return PlanExecutionGateResult(
        allowed: false,
        reason: 'task_update_required',
        currentStep: currentStep,
        requiresTaskUpdateBeforeTool: true,
      );
    }

    if (currentStep.status == StepStatus.running) {
      final argTaskId = arguments['taskId'];
      if (argTaskId != null && argTaskId != currentStep.id) {
        return PlanExecutionGateResult(
          allowed: false,
          reason: 'task_id_mismatch',
          currentStep: currentStep,
        );
      }

      final argConnectionId = arguments['connectionId'];
      if (argConnectionId != null &&
          currentStep.connectionId != null &&
          currentStep.connectionId!.trim().isNotEmpty &&
          argConnectionId != currentStep.connectionId) {
        return PlanExecutionGateResult(
          allowed: false,
          reason: 'connection_mismatch',
          currentStep: currentStep,
        );
      }

      return PlanExecutionGateResult(
        allowed: true,
        currentStep: currentStep,
      );
    }

    return PlanExecutionGateResult(
      allowed: false,
      reason: 'invalid_step_state',
      currentStep: currentStep,
    );
  }

  static AiTodoStep? findCurrentStep(List<AiTodoStep> steps) {
    return const PlanExecutionController().snapshot(steps).currentStep;
  }

  PlanExecutionSnapshot snapshot(List<AiTodoStep> steps) {
    if (steps.isEmpty) {
      return const PlanExecutionSnapshot(
        phase: PlanExecutionPhase.none,
        steps: [],
        currentStepIndex: null,
        currentStep: null,
        hasFailedStep: false,
        isCompleted: true,
      );
    }

    int? currentStepIndex;
    AiTodoStep? currentStep;

    final runningIndex =
        steps.indexWhere((s) => s.status == StepStatus.running);
    if (runningIndex != -1) {
      currentStepIndex = runningIndex;
      currentStep = steps[runningIndex];
    } else {
      final pendingIndex =
          steps.indexWhere((s) => s.status == StepStatus.pending);
      if (pendingIndex != -1) {
        currentStepIndex = pendingIndex;
        currentStep = steps[pendingIndex];
      }
    }

    final hasFailedStep = steps.any((s) => s.status == StepStatus.failed);
    final hasActiveSteps = steps.any((s) =>
        s.status == StepStatus.pending || s.status == StepStatus.running);
    final isCompleted = !hasActiveSteps;

    final PlanExecutionPhase phase;
    if (runningIndex != -1) {
      phase = PlanExecutionPhase.running;
    } else if (hasFailedStep && hasActiveSteps) {
      phase = PlanExecutionPhase.blockedByFailure;
    } else if (isCompleted) {
      phase = PlanExecutionPhase.completed;
    } else {
      phase = PlanExecutionPhase.pending;
    }

    return PlanExecutionSnapshot(
      phase: phase,
      steps: steps,
      currentStepIndex: currentStepIndex,
      currentStep: currentStep,
      hasFailedStep: hasFailedStep,
      isCompleted: isCompleted,
    );
  }

  PlanExecutionValidationResult validateTransition({
    required List<AiTodoStep> steps,
    required String targetTaskId,
    required StepStatus nextStatus,
  }) {
    final targetIndex = steps.indexWhere((s) => s.id == targetTaskId);
    if (targetIndex == -1) {
      return const PlanExecutionValidationResult.denied(
        'Task step not found in the plan.',
        'task_not_found',
      );
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
            '${currentStatus.name} cannot be modified.',
        'completed_task_locked',
      );
    }

    // Rule 2: Cannot jump states out of order (e.g. pending directly to success)
    if (currentStatus == StepStatus.pending) {
      if (nextStatus != StepStatus.running &&
          nextStatus != StepStatus.skipped) {
        return PlanExecutionValidationResult.denied(
          'Invalid transition: task "${currentStep.name}" must go from pending to running or skipped. '
              'Cannot jump directly from pending to ${nextStatus.name}.',
          'invalid_transition',
        );
      }
    } else if (currentStatus == StepStatus.running) {
      if (nextStatus != StepStatus.success &&
          nextStatus != StepStatus.failed &&
          nextStatus != StepStatus.skipped) {
        return PlanExecutionValidationResult.denied(
          'Invalid transition: running task "${currentStep.name}" can only transition to success, failed, or skipped.',
          'invalid_transition',
        );
      }
    }

    // Rule 3: Sequenced ordering check for "running" or "skipped"
    if (nextStatus == StepStatus.running || nextStatus == StepStatus.skipped) {
      // Check if any other task is currently running (only for nextStatus == running)
      if (nextStatus == StepStatus.running) {
        final runningIndex =
            steps.indexWhere((s) => s.status == StepStatus.running);
        if (runningIndex != -1 && runningIndex != targetIndex) {
          return PlanExecutionValidationResult.denied(
            'Order violation: cannot start task "${currentStep.name}" because task '
                '"${steps[runningIndex].name}" is currently running. Only one task can run at a time.',
            'multiple_running',
          );
        }
      }

      // Check if all preceding steps are completed
      for (var i = 0; i < targetIndex; i++) {
        final priorStep = steps[i];
        if (priorStep.status == StepStatus.pending ||
            priorStep.status == StepStatus.running) {
          final actionName =
              nextStatus == StepStatus.running ? 'start' : 'skip';
          return PlanExecutionValidationResult.denied(
            'Order violation: cannot $actionName task "${currentStep.name}" because a preceding task '
                '"${priorStep.name}" is in state ${priorStep.status.name}. Execute tasks in order.',
            'order_violation',
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
                '"${priorStep.name}" failed. Resolve the failure first.',
            'failed_dependency',
          );
        }
      }
    }

    return const PlanExecutionValidationResult.allowed();
  }
}
