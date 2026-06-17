import 'dart:convert';

import 'agent/plan_execution_controller.dart';
import 'app_settings.dart';
import 'storage_service.dart';

String buildApprovedPlanExecutionContext({
  required String userText,
  required AiChatMessageRecord planMessage,
  required AppLanguage language,
}) {
  final isEn = language == AppLanguage.en;
  final steps = planMessage.todoSteps
      .map((step) => {
            'taskId': step.id,
            'name': step.name,
            'command': step.command,
            'description': step.description,
            if (step.connectionId?.trim().isNotEmpty == true)
              'connectionId': step.connectionId,
          })
      .toList(growable: false);

  final snapshot = const PlanExecutionController().snapshot(planMessage.todoSteps);
  final currentTodoStep = snapshot.currentStep;
  final phaseName = snapshot.phase.name;
  final currentStepText = currentTodoStep == null
      ? (isEn ? 'All tasks in the plan are completed.' : '计划中的所有任务已完成。')
      : (isEn
          ? 'Current task to execute:\n${jsonEncode({
              'taskId': currentTodoStep.id,
              'name': currentTodoStep.name,
              'command': currentTodoStep.command,
              'status': currentTodoStep.status.name,
            })}'
          : '当前应执行任务：\n${jsonEncode({
              'taskId': currentTodoStep.id,
              'name': currentTodoStep.name,
              'command': currentTodoStep.command,
              'status': currentTodoStep.status.name,
            })}');

  final rulesText = isEn
      ? 'Execution Rules:\n'
          '1. Only update the current task unless marking the previous task finished.\n'
          '2. Do not skip ahead or run steps out of order.\n'
          '3. If a task fails, stop execution and report the failure immediately unless the user explicitly tells you to continue.'
      : '执行规则：\n'
          '1. 只能更新当前要执行的任务，除非你正在将上一个运行中的任务标记为已完成。\n'
          '2. 请勿跳步或无序执行。\n'
          '3. 一旦有任务执行失败 (failed)，必须立即停止后续执行并向用户汇报错误，除非用户明确指示你继续。';

  return [
    isEn ? 'Approved execution plan:' : '已批准执行计划：',
    isEn
        ? 'Use these persisted todoSteps as the source of truth. Execute them sequentially in order. Do not recreate task ids or reparse any earlier playbook text.'
        : '以下持久化 todoSteps 是唯一执行依据。请严格按顺序执行，不要重新创建 taskId，也不要重新解析旧的 playbook 文本。',
    isEn
        ? 'Call client_task_update with status="running" when each step starts, then update it to success, failed, or skipped with stdout/stderr when the step finishes.'
        : '每一步开始时调用 client_task_update(status="running")，完成后再更新为 success、failed 或 skipped，并尽量写入 stdout/stderr。',
    isEn ? 'Persisted steps:' : '持久化步骤：',
    jsonEncode(steps),
    '',
    isEn ? 'Plan execution phase: $phaseName' : '计划执行阶段：$phaseName',
    if (snapshot.phase == PlanExecutionPhase.blockedByFailure)
      isEn
          ? 'Warning: A preceding step has failed. Do not execute subsequent steps unless explicitly instructed by the user.'
          : '警告：已有前置任务失败。除非用户明确要求继续，否则不要执行后续任务。',
    '',
    currentStepText,
    '',
    rulesText,
    '',
    isEn ? 'User execution trigger:' : '用户执行触发：',
    userText,
  ].join('\n');
}
