import 'dart:convert';

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
    isEn ? 'User execution trigger:' : '用户执行触发：',
    userText,
  ].join('\n');
}
