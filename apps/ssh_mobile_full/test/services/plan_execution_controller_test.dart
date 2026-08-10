import 'package:flutter_test/flutter_test.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:feature_ai/ai_agent.dart';
import 'package:feature_ai/ai_approved_plan.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  group('PlanExecutionController state machine tests', () {
    const controller = PlanExecutionController();

    test('all pending steps -> findCurrentStep returns the first one', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.pending,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final current = PlanExecutionController.findCurrentStep(steps);
      expect(current, isNotNull);
      expect(current!.id, 't-1');
    });

    test('step 1 running -> findCurrentStep returns the first one', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.running,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final current = PlanExecutionController.findCurrentStep(steps);
      expect(current, isNotNull);
      expect(current!.id, 't-1');
    });

    test('all steps success or skipped -> findCurrentStep returns null', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.success,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.skipped,
        ),
      ];

      final current = PlanExecutionController.findCurrentStep(steps);
      expect(current, isNull);
    });

    test('pending -> running transition is allowed', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isTrue);
    });

    test('running -> success/failed transition is allowed', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.running,
        ),
      ];

      final successRes = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.success,
      );
      final failedRes = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.failed,
      );
      expect(successRes.allowed, isTrue);
      expect(failedRes.allowed, isTrue);
    });

    test('jump transition (pending -> success) directly is blocked', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.success,
      );
      expect(res.allowed, isFalse);
      expect(
        res.errorMessage,
        contains('Cannot jump directly from pending to success'),
      );
    });

    test('completed step cannot transition again', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.success,
        ),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(
        res.errorMessage,
        contains('completed task "Step 1" in state success cannot be modified'),
      );
    });

    test('step 2 running while step 1 pending is blocked (out-of-order)', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.pending,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-2',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(
        res.errorMessage,
        contains(
          'Order violation: cannot start task "Step 2" because a preceding task "Step 1" is in state pending',
        ),
      );
    });

    test('multiple running steps is blocked', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.running,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-2',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(
        res.errorMessage,
        contains(
          'Order violation: cannot start task "Step 2" because task "Step 1" is currently running',
        ),
      );
    });

    test('after failed step, next pending step running is blocked', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.failed,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-2',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(
        res.errorMessage,
        contains(
          'Plan blocked: cannot execute "Step 2" because a prior step "Step 1" failed',
        ),
      );
      expect(res.code, 'failed_dependency');
    });

    test('snapshot([]) returns phase none and isCompleted', () {
      final snap = controller.snapshot([]);
      expect(snap.phase, PlanExecutionPhase.none);
      expect(snap.currentStep, isNull);
      expect(snap.isCompleted, isTrue);
    });

    test('all pending steps -> phase pending, first is current', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.pending,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'c2',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];
      final snap = controller.snapshot(steps);
      expect(snap.phase, PlanExecutionPhase.pending);
      expect(snap.currentStep!.id, 't-1');
      expect(snap.isCompleted, isFalse);
    });

    test('first running -> phase running, running is current', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.running,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'c2',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];
      final snap = controller.snapshot(steps);
      expect(snap.phase, PlanExecutionPhase.running);
      expect(snap.currentStep!.id, 't-1');
      expect(snap.isCompleted, isFalse);
    });

    test('prior failed + later pending -> phase blockedByFailure', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.failed,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'c2',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];
      final snap = controller.snapshot(steps);
      expect(snap.phase, PlanExecutionPhase.blockedByFailure);
      expect(snap.currentStep!.id, 't-2');
      expect(snap.isCompleted, isFalse);
    });

    test('all success or skipped -> phase completed', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.success,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'c2',
          description: 'd',
          status: StepStatus.skipped,
        ),
      ];
      final snap = controller.snapshot(steps);
      expect(snap.phase, PlanExecutionPhase.completed);
      expect(snap.currentStep, isNull);
      expect(snap.isCompleted, isTrue);
    });

    test('pending step 2 cannot be skipped while step 1 pending', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.pending,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'c2',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];
      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-2',
        nextStatus: StepStatus.skipped,
      );
      expect(res.allowed, isFalse);
      expect(res.code, 'order_violation');
      expect(
        res.errorMessage,
        contains(
          'cannot skip task "Step 2" because a preceding task "Step 1" is in state pending',
        ),
      );
    });

    test('running step can be skipped', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.running,
        ),
      ];
      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.skipped,
      );
      expect(res.allowed, isTrue);
    });

    test('findCurrentStep delegates to snapshot currentStep', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.failed,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'c2',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];

      final current = PlanExecutionController.findCurrentStep(steps);
      expect(current, isNotNull);
      expect(current!.id, 't-2');
    });

    test('isStepScopedTool checks step scoped criteria', () {
      expect(controller.isStepScopedTool('run_command'), isTrue);
      expect(controller.isStepScopedTool('detect_os'), isTrue);
      expect(controller.isStepScopedTool('sftp_read_text'), isTrue);
      expect(controller.isStepScopedTool('monitor_get_samples'), isTrue);
      expect(controller.isStepScopedTool('get_server_details'), isTrue);
      expect(controller.isStepScopedTool('client_task_update'), isFalse);
      expect(controller.isStepScopedTool('web_search'), isFalse);
      expect(controller.isStepScopedTool('client_time'), isFalse);
      expect(
        controller.isStepScopedTool('app_get_operational_settings'),
        isFalse,
      );
      expect(controller.isStepScopedTool('list_servers'), isFalse);
    });

    test('canRunToolForCurrentStep: empty steps is allowed', () {
      final res = controller.canRunToolForCurrentStep(
        steps: [],
        toolName: 'run_command',
        arguments: {},
      );
      expect(res.allowed, isTrue);
    });

    test('canRunToolForCurrentStep: client/app/local tool is allowed', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];
      final res = controller.canRunToolForCurrentStep(
        steps: steps,
        toolName: 'client_time',
        arguments: {},
      );
      expect(res.allowed, isTrue);
    });

    test(
      'canRunToolForCurrentStep: read-only remote tool detect_os is blocked when pending',
      () {
        final steps = [
          const AiTodoStep(
            id: 't-1',
            name: 'Step 1',
            command: 'c1',
            description: 'd',
            status: StepStatus.pending,
          ),
        ];
        final res = controller.canRunToolForCurrentStep(
          steps: steps,
          toolName: 'detect_os',
          arguments: {},
        );
        expect(res.allowed, isFalse);
        expect(res.reason, 'task_update_required');
      },
    );

    test('canRunToolForCurrentStep: completed plan blocks mutating tools', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.success,
        ),
      ];
      final res = controller.canRunToolForCurrentStep(
        steps: steps,
        toolName: 'run_command',
        arguments: {},
      );
      expect(res.allowed, isFalse);
      expect(res.reason, 'plan_completed');
    });

    test('canRunToolForCurrentStep: failed steps block execution', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.failed,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'c2',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];
      final res = controller.canRunToolForCurrentStep(
        steps: steps,
        toolName: 'run_command',
        arguments: {},
      );
      expect(res.allowed, isFalse);
      expect(res.reason, 'previous_step_failed');
    });

    test('canRunToolForCurrentStep: pending current step requires running', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'c1',
          description: 'd',
          status: StepStatus.pending,
        ),
      ];
      final res = controller.canRunToolForCurrentStep(
        steps: steps,
        toolName: 'run_command',
        arguments: {},
      );
      expect(res.allowed, isFalse);
      expect(res.reason, 'task_update_required');
      expect(res.requiresTaskUpdateBeforeTool, isTrue);
    });

    test(
      'canRunToolForCurrentStep: running status allows matching execution',
      () {
        final steps = [
          const AiTodoStep(
            id: 't-1',
            name: 'Step 1',
            command: 'c1',
            description: 'd',
            status: StepStatus.running,
            connectionId: 'conn-1',
          ),
        ];

        // Matching taskId & connectionId
        final matchRes = controller.canRunToolForCurrentStep(
          steps: steps,
          toolName: 'run_command',
          arguments: {'taskId': 't-1', 'connectionId': 'conn-1'},
        );
        expect(matchRes.allowed, isTrue);

        // Task ID mismatch
        final idMismatchRes = controller.canRunToolForCurrentStep(
          steps: steps,
          toolName: 'run_command',
          arguments: {'taskId': 't-2', 'connectionId': 'conn-1'},
        );
        expect(idMismatchRes.allowed, isFalse);
        expect(idMismatchRes.reason, 'task_id_mismatch');

        // Connection ID mismatch
        final connMismatchRes = controller.canRunToolForCurrentStep(
          steps: steps,
          toolName: 'run_command',
          arguments: {'taskId': 't-1', 'connectionId': 'conn-2'},
        );
        expect(connMismatchRes.allowed, isFalse);
        expect(connMismatchRes.reason, 'connection_mismatch');
      },
    );
  });

  group('ApprovedPlanContext context rendering tests', () {
    test('execution context contains current step and rules', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.pending,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final message = AiChatMessageRecord(
        role: 'assistant',
        text: 'plan text',
        createdAt: DateTime.now(),
        todoSteps: steps,
      );

      final contextText = buildApprovedPlanExecutionContext(
        userText: 'lets go',
        planMessage: message,
        language: AppLanguage.zh,
      );

      expect(contextText, contains('当前应执行任务：'));
      expect(contextText, contains('"taskId":"t-1"'));
      expect(contextText, contains('计划执行阶段：pending'));
      expect(contextText, contains('执行规则：'));
      expect(contextText, contains('请勿跳步或无序执行。'));
    });

    test('blockedByFailure phase includes warning', () {
      final steps = [
        const AiTodoStep(
          id: 't-1',
          name: 'Step 1',
          command: 'cmd 1',
          description: 'desc',
          status: StepStatus.failed,
        ),
        const AiTodoStep(
          id: 't-2',
          name: 'Step 2',
          command: 'cmd 2',
          description: 'desc',
          status: StepStatus.pending,
        ),
      ];

      final message = AiChatMessageRecord(
        role: 'assistant',
        text: 'plan text',
        createdAt: DateTime.now(),
        todoSteps: steps,
      );

      final contextText = buildApprovedPlanExecutionContext(
        userText: 'lets go',
        planMessage: message,
        language: AppLanguage.zh,
      );

      expect(contextText, contains('计划执行阶段：blockedByFailure'));
      expect(contextText, contains('警告：已有前置任务失败。除非用户明确要求继续，否则不要执行后续任务。'));
    });
  });
}
