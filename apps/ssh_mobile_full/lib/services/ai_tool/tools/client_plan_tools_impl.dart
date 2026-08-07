part of '../../ai_tool_service.dart';

Future<String> _clientSetPlanMode(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({
      'error': 'No active chat session found for this client tool call.',
    });
  }

  final enabled = service._optionalBool(arguments, 'enabled') ?? true;
  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({
      'error': 'Active chat record not found for id: $chatId',
    });
  }
  final currentChat = chats[chatIndex];

  if (!enabled &&
      !canExitPlanMode(currentChat, actor: PlanModeExitActor.llmTool)) {
    final isZh = service.appSettings?.language == AppLanguage.zh;
    final errorMsg = isZh
        ? '无法退出规划模式。当前聊天没有可执行的 TODO 步骤。请先在最新的回复中输出包含 steps 的 ```playbook JSON 代码块，或使用 client_task_create 创建计划步骤。'
        : 'Cannot exit Plan Mode. This plan has no executable steps. Generate a valid ```playbook JSON block with steps in your latest reply, or create steps with client_task_create first.';
    return jsonEncode({'error': errorMsg});
  }

  final updatedChat = currentChat.copyWith(
    planMode: enabled,
    updatedAt: DateTime.now(),
    clearApprovedPlan: enabled,
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'planMode': enabled,
    'message': enabled
        ? 'Successfully entered Plan Mode. State-mutating tools are restricted. Please diagnose and replan.'
        : 'Successfully exited Plan Mode. Now in execution mode. You can instruct the user to execute the TODO steps.',
  });
}

Future<String> _clientTaskCreate(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (!currentChat.planMode) {
    return jsonEncode({
      'error':
          'Task creation is blocked. client_task_create can ONLY be called during Plan Mode.',
    });
  }

  final name = service._arg(arguments, 'name');
  final command = service._optionalString(arguments, 'command') ?? '';
  final description = service._optionalString(arguments, 'description') ?? '';
  final connectionId = service._optionalString(arguments, 'connectionId');

  final messages = [...currentChat.messages];
  if (messages.isEmpty) {
    return jsonEncode({'error': 'No messages to bind the task to.'});
  }

  final assistantIndex = messages.lastIndexWhere((m) => m.role == 'assistant');
  if (assistantIndex == -1) {
    return jsonEncode({
      'error': 'No assistant message found to bind the task.',
    });
  }

  final targetMsg = messages[assistantIndex];
  final steps = [...targetMsg.todoSteps];

  final now = DateTime.now();
  final taskId = 'task-${now.microsecondsSinceEpoch}-${steps.length}';
  final newStep = AiTodoStep(
    id: taskId,
    name: name,
    command: command,
    description: description,
    status: StepStatus.pending,
    connectionId: connectionId,
  );
  steps.add(newStep);

  messages[assistantIndex] = targetMsg.copyWith(todoSteps: steps);
  final updatedChat = currentChat.copyWith(
    messages: messages,
    updatedAt: DateTime.now(),
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'taskId': taskId,
    'name': name,
    'command': command,
    'description': description,
    'message': 'Task step successfully created and appended to the plan list.',
  });
}

Future<String> _clientTaskUpdate(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (currentChat.planMode) {
    return jsonEncode({
      'error':
          'Task status update is blocked. client_task_update can ONLY be called during Execution Mode.',
    });
  }

  final taskId = service._arg(arguments, 'taskId');
  final String rawStatus = service._arg(arguments, 'status').trim();
  final allowedStatuses = [
    'pending',
    'running',
    'in_progress',
    'success',
    'failed',
    'skipped',
  ];
  if (!allowedStatuses.contains(rawStatus.toLowerCase())) {
    return jsonEncode({
      'error': 'Unknown task status.',
      'code': 'invalid_task_status',
      'allowed': ['pending', 'running', 'success', 'failed', 'skipped'],
    });
  }

  final nextStatus = _taskStatusFromRaw(provider, rawStatus);
  if (nextStatus == StepStatus.skipped) {
    final reason = service._optionalString(arguments, 'reason');
    if (reason == null || reason.trim().isEmpty) {
      return jsonEncode({
        'error': 'Skipping a task requires a reason.',
        'code': 'skip_reason_required',
      });
    }
  }

  final stdout = service._optionalString(arguments, 'stdout');
  final stderr = service._optionalString(arguments, 'stderr');
  final errorSummary = service._optionalString(arguments, 'errorSummary');

  bool foundAndUpdated = false;
  final messages = [...currentChat.messages];
  AiTodoStep? updatedStep;

  for (var mIdx = 0; mIdx < messages.length; mIdx++) {
    final msg = messages[mIdx];
    if (msg.todoSteps.isEmpty) continue;

    final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
    if (sIdx != -1) {
      final steps = [...msg.todoSteps];
      final currentStep = steps[sIdx];

      const planController = PlanExecutionController();
      final validation = planController.validateTransition(
        steps: steps,
        targetTaskId: taskId,
        nextStatus: nextStatus,
      );

      if (!validation.allowed) {
        return jsonEncode({
          'error':
              'Plan execution validation failed: ${validation.errorMessage}',
        });
      }

      final combinedStderr = [
        if (stderr?.trim().isNotEmpty == true) stderr!.trim(),
        if (errorSummary?.trim().isNotEmpty == true)
          'Error Summary: ${errorSummary!.trim()}',
      ].join('\n');

      steps[sIdx] = currentStep.copyWith(
        status: nextStatus,
        stdout: stdout ?? currentStep.stdout,
        stderr: combinedStderr.isNotEmpty ? combinedStderr : currentStep.stderr,
        exitCode: nextStatus == StepStatus.success
            ? 0
            : (nextStatus == StepStatus.failed ? 1 : currentStep.exitCode),
      );

      updatedStep = steps[sIdx];
      messages[mIdx] = msg.copyWith(todoSteps: steps);
      foundAndUpdated = true;
      break;
    }
  }

  if (!foundAndUpdated || updatedStep == null) {
    return jsonEncode({
      'error':
          'Task step not found. No task with id: $taskId exists in this chat session.',
    });
  }

  final updatedChat = currentChat.copyWith(
    messages: messages,
    updatedAt: DateTime.now(),
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'taskId': taskId,
    'newStatus': nextStatus.name,
    'message': 'Task step successfully updated in the execution logs.',
    if (nextStatus == StepStatus.running) ...{
      if (updatedStep.command.trim().isNotEmpty)
        'expectedCommand': updatedStep.command,
      if (updatedStep.connectionId?.trim().isNotEmpty == true)
        'expectedConnectionId': updatedStep.connectionId,
    },
    if (nextStatus == StepStatus.failed) ...{
      'nextAction':
          'Stop execution and ask the user whether to retry, skip, or revise the plan.',
      'options': ['retry_current_step', 'skip_current_step', 'ask_user'],
    },
  });
}

StepStatus _taskStatusFromRaw(ClientToolsProvider provider, String rawStatus) {
  final normalized = rawStatus.trim().toLowerCase();
  if (normalized == 'in_progress') {
    return StepStatus.running;
  }
  return StepStatus.values.firstWhere(
    (e) => e.name == normalized,
    orElse: () => StepStatus.pending,
  );
}

Future<String> _clientTaskRetry(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments,
) async {
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (currentChat.planMode) {
    return jsonEncode({
      'error': 'client_task_retry can ONLY be called during Execution Mode.',
    });
  }

  final taskId = service._arg(arguments, 'taskId');
  final reason = service._optionalString(arguments, 'reason');
  bool foundAndUpdated = false;
  final messages = [...currentChat.messages];

  for (var mIdx = 0; mIdx < messages.length; mIdx++) {
    final msg = messages[mIdx];
    if (msg.todoSteps.isEmpty) continue;

    final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
    if (sIdx != -1) {
      final steps = [...msg.todoSteps];
      final currentStep = steps[sIdx];

      if (currentStep.status != StepStatus.failed) {
        return jsonEncode({
          'error':
              'Only failed tasks can be retried. Current status is: ${currentStep.status.name}',
        });
      }

      steps[sIdx] = currentStep.copyWith(
        status: StepStatus.pending,
        stdout: '',
        stderr: '',
        exitCode: null,
      );

      messages[mIdx] = msg.copyWith(todoSteps: steps);
      foundAndUpdated = true;
      break;
    }
  }

  if (!foundAndUpdated) {
    return jsonEncode({'error': 'Task step not found: $taskId'});
  }

  final updatedChat = currentChat.copyWith(
    messages: messages,
    updatedAt: DateTime.now(),
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'taskId': taskId,
    'newStatus': StepStatus.pending.name,
    'message': 'Task step successfully reset to pending for retry.',
    if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
  });
}

Future<String> _clientTaskSkip(
  ClientToolsProvider provider,
  AiToolService service,
  Map<String, dynamic> arguments, {
  required bool approvedWrite,
}) async {
  if (!approvedWrite) {
    return jsonEncode({'error': 'Skipping a task requires user approval.'});
  }
  final chatId = provider.clientWebViewSessionId;
  if (chatId == null || chatId.trim().isEmpty) {
    return jsonEncode({'error': 'No active chat session found.'});
  }

  final chats = await provider.storageService.loadAiChats();
  final chatIndex = chats.indexWhere((c) => c.id == chatId);
  if (chatIndex == -1) {
    return jsonEncode({'error': 'Active chat record not found.'});
  }
  final currentChat = chats[chatIndex];

  if (currentChat.planMode) {
    return jsonEncode({
      'error': 'client_task_skip can ONLY be called during Execution Mode.',
    });
  }

  final taskId = service._arg(arguments, 'taskId');
  final reason = service._arg(arguments, 'reason');
  if (reason.trim().isEmpty) {
    return jsonEncode({
      'error': 'Skipping a task requires a reason.',
      'code': 'skip_reason_required',
    });
  }

  bool foundAndUpdated = false;
  final messages = [...currentChat.messages];

  for (var mIdx = 0; mIdx < messages.length; mIdx++) {
    final msg = messages[mIdx];
    if (msg.todoSteps.isEmpty) continue;

    final sIdx = msg.todoSteps.indexWhere((s) => s.id == taskId);
    if (sIdx != -1) {
      final steps = [...msg.todoSteps];
      final currentStep = steps[sIdx];

      if (currentStep.status != StepStatus.pending &&
          currentStep.status != StepStatus.failed) {
        return jsonEncode({
          'error':
              'Only pending or failed tasks can be skipped. Current status is: ${currentStep.status.name}',
          'code': 'invalid_skip_state',
        });
      }

      steps[sIdx] = currentStep.copyWith(
        status: StepStatus.skipped,
        stdout: 'Skipped: $reason',
        exitCode: null,
      );

      messages[mIdx] = msg.copyWith(todoSteps: steps);
      foundAndUpdated = true;
      break;
    }
  }

  if (!foundAndUpdated) {
    return jsonEncode({'error': 'Task step not found: $taskId'});
  }

  final updatedChat = currentChat.copyWith(
    messages: messages,
    updatedAt: DateTime.now(),
  );
  await provider.storageService.saveAiChat(updatedChat);

  return jsonEncode({
    'status': 'success',
    'taskId': taskId,
    'newStatus': StepStatus.skipped.name,
    'message': 'Task step successfully marked as skipped.',
  });
}
