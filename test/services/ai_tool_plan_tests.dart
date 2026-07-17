part of 'ai_tool_service_test.dart';

void _registerAiToolPlanTests() {
  group('client_set_plan_mode tool', () {
    test(
      'switches planMode to true, clears approved plan, and exits only with persisted latest todo steps',
      () async {
        final now = DateTime.now();
        var chat = AiChatRecord(
          id: 'chat-1',
          title: 'Draft',
          model: 'deepseek-v4-flash',
          messages: const [],
          createdAt: now,
          updatedAt: now,
          planMode: false,
          approvedPlan: AiApprovedPlanRef(
            assistantCreatedAt: now,
            approvedAt: now,
          ),
        );
        await storage.saveAiChat(chat);

        // 1. 开启 planMode
        final rawTrue = await tools.execute('client_set_plan_mode', {
          'enabled': true,
        });
        final decodedTrue = jsonDecode(rawTrue) as Map<String, dynamic>;
        expect(decodedTrue['status'], 'success');
        expect(decodedTrue['planMode'], isTrue);

        final chatTrue = (await storage.loadAiChats()).firstWhere(
          (c) => c.id == 'chat-1',
        );
        expect(chatTrue.planMode, isTrue);
        expect(chatTrue.approvedPlan, isNull);

        // 2. 尝试关闭 planMode（因为没有任何 playbook 计划，应该被拦截报错）
        final rawFalse = await tools.execute('client_set_plan_mode', {
          'enabled': false,
        });
        final decodedFalse = jsonDecode(rawFalse) as Map<String, dynamic>;
        expect(
          decodedFalse['error'],
          anyOf(contains('Cannot exit Plan Mode'), contains('无法退出规划模式')),
        );

        final chatStillTrue = (await storage.loadAiChats()).firstWhere(
          (c) => c.id == 'chat-1',
        );
        expect(chatStillTrue.planMode, isTrue);

        // 3. 往会话中添加一条带有 playbook 计划步骤的消息
        final updatedChat = chatStillTrue.copyWith(
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Earlier valid plan',
              createdAt: now.subtract(const Duration(minutes: 1)),
              todoSteps: const [
                AiTodoStep(
                  id: 'task-old',
                  name: 'Earlier plan',
                  command: 'echo old',
                  description: 'old',
                ),
              ],
            ),
            AiChatMessageRecord(
              role: 'assistant',
              text: 'Latest executable plan',
              createdAt: now,
              todoSteps: const [
                AiTodoStep(
                  id: 'task-new',
                  name: 'Step 1',
                  command: 'echo ok',
                  description: 'Persisted plan step',
                ),
              ],
            ),
          ],
        );
        await storage.saveAiChat(updatedChat);

        // 4. 再次尝试关闭 planMode（此时符合条件，应允许退出）
        final rawExit = await tools.execute('client_set_plan_mode', {
          'enabled': false,
        });
        final decodedExit = jsonDecode(rawExit) as Map<String, dynamic>;
        expect(decodedExit['status'], 'success');
        expect(decodedExit['planMode'], isFalse);

        final chatFalse = (await storage.loadAiChats()).firstWhere(
          (c) => c.id == 'chat-1',
        );
        expect(chatFalse.planMode, isFalse);
      },
    );
  });

  group('client_task_create and client_task_update flow and constraints', () {
    test('enforces planMode時机限制与数据防篡改', () async {
      final now = DateTime.now();

      // 1. 初始化 ChatRecord，最后一客助理消息，并且处于 planMode = true
      var chat = AiChatRecord(
        id: 'chat-1',
        title: 'Draft',
        model: 'deepseek-v4-flash',
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'Let me plan...',
            createdAt: now,
          ),
        ],
        createdAt: now,
        updatedAt: now,
        planMode: true,
      );
      await storage.saveAiChat(chat);

      // 2. 处于 Plan Mode，调用 TaskCreate 应成功
      final rawCreate = await tools.execute('client_task_create', {
        'name': 'Install Docker',
        'command': 'curl -fsSL https://get.docker.com | sh',
        'description': 'Install docker engine',
      });
      final decodedCreate = jsonDecode(rawCreate) as Map<String, dynamic>;
      expect(decodedCreate['status'], 'success');
      final taskId = decodedCreate['taskId'] as String;
      expect(taskId, startsWith('task-'));

      // 验证是否已存入助理消息的 todoSteps
      final chatAfterCreate = (await storage.loadAiChats()).firstWhere(
        (c) => c.id == 'chat-1',
      );
      expect(chatAfterCreate.messages.last.todoSteps.length, 1);
      expect(chatAfterCreate.messages.last.todoSteps.first.id, taskId);

      // 3. 处于 Plan Mode，调用 TaskUpdate 应该被拦截报错
      final rawUpdateInPlan = await tools.execute('client_task_update', {
        'taskId': taskId,
        'status': 'success',
      });
      final decodedUpdateInPlan =
          jsonDecode(rawUpdateInPlan) as Map<String, dynamic>;
      expect(
        decodedUpdateInPlan['error'],
        contains('client_task_update can ONLY be called during Execution Mode'),
      );

      // 4. 将 Chat 设为 planMode = false (执行模式)
      final chatExecution = chatAfterCreate.copyWith(planMode: false);
      await storage.saveAiChat(chatExecution);

      // 5. 处于 Execution Mode，调用 TaskCreate 应该被拦截报错
      final rawCreateInExec = await tools.execute('client_task_create', {
        'name': 'Another Step',
      });
      final decodedCreateInExec =
          jsonDecode(rawCreateInExec) as Map<String, dynamic>;
      expect(
        decodedCreateInExec['error'],
        contains('client_task_create can ONLY be called during Plan Mode'),
      );

      // 6. 处于 Execution Mode，调用 TaskUpdate 应该成功并更新状态
      final rawRunningAlias = await tools.execute('client_task_update', {
        'taskId': taskId,
        'status': 'in_progress',
      });
      final decodedRunningAlias =
          jsonDecode(rawRunningAlias) as Map<String, dynamic>;
      expect(decodedRunningAlias['status'], 'success');
      expect(decodedRunningAlias['newStatus'], 'running');

      final chatAfterAlias = (await storage.loadAiChats()).firstWhere(
        (c) => c.id == 'chat-1',
      );
      expect(
        chatAfterAlias.messages.last.todoSteps.first.status.name,
        'running',
      );

      final rawUpdate = await tools.execute('client_task_update', {
        'taskId': taskId,
        'status': 'success',
        'stdout': 'Docker version 24.0.7',
      });
      final decodedUpdate = jsonDecode(rawUpdate) as Map<String, dynamic>;
      expect(decodedUpdate['status'], 'success');
      expect(decodedUpdate['newStatus'], 'success');

      final chatAfterUpdate = (await storage.loadAiChats()).firstWhere(
        (c) => c.id == 'chat-1',
      );
      final updatedStep = chatAfterUpdate.messages.last.todoSteps.first;
      expect(updatedStep.status.name, 'success');
      expect(updatedStep.stdout, 'Docker version 24.0.7');

      // 7. 处于 Execution Mode，但调用不存在的 taskId 应该报错
      final rawUpdateInvalid = await tools.execute('client_task_update', {
        'taskId': 'invalid-id',
        'status': 'success',
      });
      final decodedUpdateInvalid =
          jsonDecode(rawUpdateInvalid) as Map<String, dynamic>;
      expect(decodedUpdateInvalid['error'], contains('Task step not found'));
    });

    test(
      'enforces strict status validations and expected commands for task updates',
      () async {
        final now = DateTime.now();
        var chat = AiChatRecord(
          id: 'chat-1',
          title: 'Draft',
          model: 'deepseek-v4-flash',
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: now,
              todoSteps: [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Step 1',
                  command: 'echo ok',
                  description: 'Persisted plan step',
                  status: StepStatus.pending,
                  connectionId: 'server-1',
                ),
              ],
            ),
          ],
          createdAt: now,
          updatedAt: now,
          planMode: false,
        );
        await storage.saveAiChat(chat);

        // 1. Invalid status
        final rawInvalid = await tools.execute('client_task_update', {
          'taskId': 'task-1',
          'status': 'unknown_status',
        });
        final decodedInvalid = jsonDecode(rawInvalid) as Map<String, dynamic>;
        expect(decodedInvalid['code'], 'invalid_task_status');
        expect(decodedInvalid['allowed'], contains('running'));

        // 2. Skipped status requires reason
        final rawSkippedNoReason = await tools.execute('client_task_update', {
          'taskId': 'task-1',
          'status': 'skipped',
        });
        final decodedSkippedNoReason =
            jsonDecode(rawSkippedNoReason) as Map<String, dynamic>;
        expect(decodedSkippedNoReason['code'], 'skip_reason_required');

        // 3. Skipped with reason succeeds
        final rawSkippedWithReason = await tools.execute('client_task_update', {
          'taskId': 'task-1',
          'status': 'skipped',
          'reason': 'not needed',
        });
        final decodedSkippedWithReason =
            jsonDecode(rawSkippedWithReason) as Map<String, dynamic>;
        expect(decodedSkippedWithReason['status'], 'success');

        // Reset step to pending and running to test running output payload
        final resetChat = chat.copyWith(
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: now,
              todoSteps: [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Step 1',
                  command: 'echo ok',
                  description: 'Persisted plan step',
                  status: StepStatus.pending,
                  connectionId: 'server-1',
                ),
              ],
            ),
          ],
        );
        await storage.saveAiChat(resetChat);

        final rawRunning = await tools.execute('client_task_update', {
          'taskId': 'task-1',
          'status': 'running',
        });
        final decodedRunning = jsonDecode(rawRunning) as Map<String, dynamic>;
        expect(decodedRunning['status'], 'success');
        expect(decodedRunning['expectedCommand'], 'echo ok');
        expect(decodedRunning['expectedConnectionId'], 'server-1');

        // Update to failed
        final rawFailed = await tools.execute('client_task_update', {
          'taskId': 'task-1',
          'status': 'failed',
          'errorSummary': 'failed execution',
        });
        final decodedFailed = jsonDecode(rawFailed) as Map<String, dynamic>;
        expect(decodedFailed['status'], 'success');
        expect(decodedFailed['newStatus'], 'failed');
        expect(decodedFailed['nextAction'], contains('Stop execution'));

        final chatFailed = (await storage.loadAiChats()).firstWhere(
          (c) => c.id == 'chat-1',
        );
        expect(
          chatFailed.messages.last.todoSteps.first.stderr,
          contains('Error Summary: failed execution'),
        );
      },
    );

    test(
      'client_task_retry and client_task_skip control execution step flows',
      () async {
        final now = DateTime.now();
        var chat = AiChatRecord(
          id: 'chat-1',
          title: 'Draft',
          model: 'deepseek-v4-flash',
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: now,
              todoSteps: [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Step 1',
                  command: 'echo ok',
                  description: 'Persisted plan step',
                  status: StepStatus.failed,
                ),
              ],
            ),
          ],
          createdAt: now,
          updatedAt: now,
          planMode: false,
        );
        await storage.saveAiChat(chat);

        // 1. Retry failed step -> should reset to pending
        final rawRetry = await tools.execute('client_task_retry', {
          'taskId': 'task-1',
          'reason': 'retrying for correction',
        });
        final decodedRetry = jsonDecode(rawRetry) as Map<String, dynamic>;
        expect(decodedRetry['status'], 'success');
        expect(decodedRetry['newStatus'], 'pending');
        expect(decodedRetry['reason'], 'retrying for correction');

        final chatAfterRetry = (await storage.loadAiChats()).firstWhere(
          (c) => c.id == 'chat-1',
        );
        expect(
          chatAfterRetry.messages.last.todoSteps.first.status,
          StepStatus.pending,
        );

        // 2. Retry non-failed step -> should fail
        final rawRetryPending = await tools.execute('client_task_retry', {
          'taskId': 'task-1',
        });
        final decodedRetryPending =
            jsonDecode(rawRetryPending) as Map<String, dynamic>;
        expect(
          decodedRetryPending['error'],
          contains('Only failed tasks can be retried'),
        );

        // 3. Skip pending step without approval -> should fail
        final rawSkipNoApproval = await tools.execute('client_task_skip', {
          'taskId': 'task-1',
          'reason': 'manual override',
        });
        expect(
          jsonDecode(rawSkipNoApproval)['error'],
          contains('requires user approval'),
        );

        // 4. Skip pending step with approval -> should mark skipped with reason in stdout
        final rawSkip = await tools.execute('client_task_skip', {
          'taskId': 'task-1',
          'reason': 'manual override',
        }, approvedWrite: true);
        final decodedSkip = jsonDecode(rawSkip) as Map<String, dynamic>;
        expect(decodedSkip['status'], 'success');
        expect(decodedSkip['newStatus'], 'skipped');

        final chatAfterSkip = (await storage.loadAiChats()).firstWhere(
          (c) => c.id == 'chat-1',
        );
        final skippedStep = chatAfterSkip.messages.last.todoSteps.first;
        expect(skippedStep.status, StepStatus.skipped);
        expect(skippedStep.stdout, contains('Skipped: manual override'));

        // 5. Try to skip a running task -> should fail
        final chatRunning = chat.copyWith(
          messages: [
            AiChatMessageRecord(
              role: 'assistant',
              text: 'plan',
              createdAt: now,
              todoSteps: [
                AiTodoStep(
                  id: 'task-1',
                  name: 'Step 1',
                  command: 'echo ok',
                  description: 'Persisted plan step',
                  status: StepStatus.running,
                ),
              ],
            ),
          ],
        );
        await storage.saveAiChat(chatRunning);

        final rawSkipRunning = await tools.execute('client_task_skip', {
          'taskId': 'task-1',
          'reason': 'manual override',
        }, approvedWrite: true);
        final decodedSkipRunning =
            jsonDecode(rawSkipRunning) as Map<String, dynamic>;
        expect(
          decodedSkipRunning['error'],
          contains('Only pending or failed tasks can be skipped'),
        );
        expect(decodedSkipRunning['code'], 'invalid_skip_state');

        // 6. Verify approvalRequestFor generates correct request for client_task_skip
        final skipRequest = await tools.approvalRequestFor('client_task_skip', {
          'taskId': 'task-1',
          'reason': 'manual override',
        });
        expect(skipRequest, isNotNull);
        expect(skipRequest!.approvalType, 'plan_task_change');
        expect(skipRequest.command, contains('SKIP PLAN TASK task-1'));
        expect(skipRequest.contentPreview, contains('Reason: manual override'));
      },
    );
  });
}
