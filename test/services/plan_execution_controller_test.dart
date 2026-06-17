import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/agent/plan_execution_controller.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/approved_plan_context.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  group('PlanExecutionController state machine tests', () {
    const controller = PlanExecutionController();

    test('all pending steps -> findCurrentStep returns the first one', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.pending),
        const AiTodoStep(id: 't-2', name: 'Step 2', command: 'cmd 2', description: 'desc', status: StepStatus.pending),
      ];

      final current = PlanExecutionController.findCurrentStep(steps);
      expect(current, isNotNull);
      expect(current!.id, 't-1');
    });

    test('step 1 running -> findCurrentStep returns the first one', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.running),
        const AiTodoStep(id: 't-2', name: 'Step 2', command: 'cmd 2', description: 'desc', status: StepStatus.pending),
      ];

      final current = PlanExecutionController.findCurrentStep(steps);
      expect(current, isNotNull);
      expect(current!.id, 't-1');
    });

    test('all steps success or skipped -> findCurrentStep returns null', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.success),
        const AiTodoStep(id: 't-2', name: 'Step 2', command: 'cmd 2', description: 'desc', status: StepStatus.skipped),
      ];

      final current = PlanExecutionController.findCurrentStep(steps);
      expect(current, isNull);
    });

    test('pending -> running transition is allowed', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.pending),
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
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.running),
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
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.pending),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.success,
      );
      expect(res.allowed, isFalse);
      expect(res.errorMessage, contains('Cannot jump directly from pending to success'));
    });

    test('completed step cannot transition again', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.success),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-1',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(res.errorMessage, contains('completed task "Step 1" in state success cannot be modified'));
    });

    test('step 2 running while step 1 pending is blocked (out-of-order)', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.pending),
        const AiTodoStep(id: 't-2', name: 'Step 2', command: 'cmd 2', description: 'desc', status: StepStatus.pending),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-2',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(res.errorMessage, contains('Order violation: cannot start task "Step 2" because a preceding task "Step 1" is in state pending'));
    });

    test('multiple running steps is blocked', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.running),
        const AiTodoStep(id: 't-2', name: 'Step 2', command: 'cmd 2', description: 'desc', status: StepStatus.pending),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-2',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(res.errorMessage, contains('Order violation: cannot start task "Step 2" because task "Step 1" is currently running'));
    });

    test('after failed step, next pending step running is blocked', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.failed),
        const AiTodoStep(id: 't-2', name: 'Step 2', command: 'cmd 2', description: 'desc', status: StepStatus.pending),
      ];

      final res = controller.validateTransition(
        steps: steps,
        targetTaskId: 't-2',
        nextStatus: StepStatus.running,
      );
      expect(res.allowed, isFalse);
      expect(res.errorMessage, contains('Plan blocked: cannot execute "Step 2" because a prior step "Step 1" failed'));
    });
  });

  group('ApprovedPlanContext context rendering tests', () {
    test('execution context contains current step and rules', () {
      final steps = [
        const AiTodoStep(id: 't-1', name: 'Step 1', command: 'cmd 1', description: 'desc', status: StepStatus.pending),
        const AiTodoStep(id: 't-2', name: 'Step 2', command: 'cmd 2', description: 'desc', status: StepStatus.pending),
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
      expect(contextText, contains('执行规则：'));
      expect(contextText, contains('请勿跳步或无序执行。'));
    });
  });
}
