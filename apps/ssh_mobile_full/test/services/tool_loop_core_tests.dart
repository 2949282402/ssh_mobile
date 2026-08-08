part of 'tool_loop_controller_test.dart';

void _registerToolLoopCoreTests() {
  test('read-only tool repeated identical call uses cache', () async {
    final budget = LlmToolBudgetController(baseBudget: 10);
    final cache = <String, CachedToolResult>{};
    final ledger = <LlmToolLedgerEntry>[];
    final controller = ToolLoopController(
      chatService: llm,
      toolBudget: budget,
      readOnlyToolCache: cache,
      toolLedger: ledger,
    );

    // 预先给缓存写入一个值
    final signature = LlmToolLedgerEntry.buildSignature(
      'client_time',
      const {},
    );
    cache[signature] = CachedToolResult(
      result: jsonEncode({'time': '2026-06-17 12:00:00'}),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );

    final workingMessages = <Map<String, dynamic>>[];
    final settings = await storage.loadAiConnectionSettings();

    final loopResult = await controller.handleToolCalls(
      toolCalls: [
        StreamingToolCall(id: 'call_1', name: 'client_time', arguments: '{}'),
      ],
      visibleToolsByName: {
        'client_time': AiTool(
          name: 'client_time',
          description: 'Get client time',
          properties: const {},
          required: const [],
          executionMode: AiToolExecutionMode.readOnly,
          cacheTtl: const Duration(minutes: 5),
          handler: (args, {approvedWrite = false}) async => '{}',
        ),
      },
      planMode: false,
      language: AppLanguage.zh,
      apiKey: 'key',
      auditModel: 'audit-model',
      originalUserGoal: 'Goal',
      workingMessages: workingMessages,
      requestToolApproval: null,
      onTrace: null,
      cancellationToken: null,
      settings: settings,
      complete: (role, messages, {required thinkingSettings}) async => 'advice',
      classify: (messages) async => '{}',
    );
    expect(loopResult.shouldStop, isFalse);
    expect(controller.cacheHitCount, 1);
    expect(workingMessages.length, 1);
    expect(workingMessages.first['content'], contains('2026-06-17 12:00:00'));
  });

  test('parallel-safe read-only tools execute as a traced batch', () async {
    final budget = LlmToolBudgetController(baseBudget: 10);
    final cache = <String, CachedToolResult>{};
    final ledger = <LlmToolLedgerEntry>[];
    final traces = <LlmTraceEvent>[];
    final controller = ToolLoopController(
      chatService: llm,
      toolBudget: budget,
      readOnlyToolCache: cache,
      toolLedger: ledger,
    );
    final settings = await storage.loadAiConnectionSettings();
    final availableTools = {
      for (final tool in await tools.tools()) tool.name: tool,
    };
    final workingMessages = <Map<String, dynamic>>[];

    final loopResult = await controller.handleToolCalls(
      toolCalls: [
        StreamingToolCall(
          id: 'call_1',
          name: 'client_get_time',
          arguments: '{}',
        ),
        StreamingToolCall(
          id: 'call_2',
          name: 'client_get_device_info',
          arguments: '{}',
        ),
      ],
      visibleToolsByName: availableTools,
      planMode: false,
      language: AppLanguage.zh,
      apiKey: 'key',
      auditModel: 'audit-model',
      originalUserGoal: 'Goal',
      workingMessages: workingMessages,
      requestToolApproval: null,
      onTrace: traces.add,
      cancellationToken: null,
      settings: settings,
      complete: (role, messages, {required thinkingSettings}) async => 'advice',
      classify: (messages) async => '{}',
    );
    expect(loopResult.shouldStop, isFalse);
    expect(budget.usedCalls, 2);
    expect(ledger.map((entry) => entry.toolName), [
      'client_get_time',
      'client_get_device_info',
    ]);
    expect(ledger.every((entry) => entry.outcome == 'success'), isTrue);
    expect(traces.any((event) => event.kind == 'tool_parallel_batch'), isTrue);
    expect(workingMessages.where((m) => m['role'] == 'tool'), hasLength(2));
  });

  test(
    'parallel-safe batch falls back to serial before budget audit boundary',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      for (var i = 0; i < 14; i++) {
        budget.recordAcceptedToolCall();
      }
      for (var i = 0; i < 3; i++) {
        budget.recordAuditTriggered();
      }
      expect(budget.currentLimit, 15);
      expect(budget.canAcceptCallsWithoutAudit(1), isTrue);
      expect(budget.canAcceptCallsWithoutAudit(2), isFalse);

      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final traces = <LlmTraceEvent>[];
      final approvals = <AiToolApprovalRequest>[];
      final controller = ToolLoopController(
        chatService: llm,
        toolBudget: budget,
        readOnlyToolCache: cache,
        toolLedger: ledger,
      );
      final settings = await storage.loadAiConnectionSettings();
      final availableTools = {
        for (final tool in await tools.tools()) tool.name: tool,
      };
      final workingMessages = <Map<String, dynamic>>[];

      final loopResult = await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call_1',
            name: 'client_get_time',
            arguments: '{}',
          ),
          StreamingToolCall(
            id: 'call_2',
            name: 'client_get_device_info',
            arguments: '{}',
          ),
        ],
        visibleToolsByName: availableTools,
        planMode: false,
        language: AppLanguage.zh,
        apiKey: 'key',
        auditModel: 'audit-model',
        originalUserGoal: 'Goal',
        workingMessages: workingMessages,
        requestToolApproval: (request) async {
          approvals.add(request);
          return const AiToolApprovalDecision.rejected(abort: false);
        },
        onTrace: traces.add,
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.finalOutcome, AgentFinalOutcome.budgetAuditRejected);
      expect(
        traces.any((event) => event.kind == 'tool_parallel_batch'),
        isFalse,
      );
      expect(approvals, hasLength(1));
      expect(approvals.single.approvalType, 'budget_audit');
      expect(budget.usedCalls, 15);
      expect(ledger.map((entry) => entry.toolName), ['client_get_time']);
      expect(workingMessages.where((m) => m['role'] == 'tool'), hasLength(2));
    },
  );

  test(
    'repeated read-only call reaches loop guard and disables tools',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final controller = ToolLoopController(
        chatService: llm,
        toolBudget: budget,
        readOnlyToolCache: cache,
        toolLedger: ledger,
      );

      final signature = LlmToolLedgerEntry.buildSignature(
        'client_time',
        const {},
      );

      // 制造 3 次相同的 read-only 账本记录
      for (var i = 0; i < 3; i++) {
        ledger.add(
          LlmToolLedgerEntry(
            index: i,
            toolName: 'client_time',
            signature: signature,
            argumentsPreview: '{}',
            outcome: 'success',
            approvalRequired: false,
            approved: false,
            failed: false,
            emptyResult: false,
            cacheHit: false,
            dedupBlocked: false,
            auditEscalationLevel: 0,
            resultPreview: '{}',
          ),
        );
      }

      final workingMessages = <Map<String, dynamic>>[];
      final settings = await storage.loadAiConnectionSettings();

      final loopResult = await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(id: 'call_4', name: 'client_time', arguments: '{}'),
        ],
        visibleToolsByName: {
          'client_time': AiTool(
            name: 'client_time',
            description: 'Get client time',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.readOnly,
            cacheTtl: const Duration(minutes: 5),
            handler: (args, {approvedWrite = false}) async => '{}',
          ),
        },
        planMode: false,
        language: AppLanguage.zh,
        apiKey: 'key',
        auditModel: 'audit-model',
        originalUserGoal: 'Goal',
        workingMessages: workingMessages,
        requestToolApproval: null,
        onTrace: null,
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.toolsShouldBeDisabled, isTrue);
      expect(controller.dedupBlockedCount, 1);
      final hasBlockedMsg = workingMessages.any(
        (m) =>
            m['role'] == 'tool' &&
            m['content'].contains('Deterministic loop guard blocked'),
      );
      expect(hasBlockedMsg, isTrue);
      expect(loopResult.finalOutcome, AgentFinalOutcome.loopGuardBlocked);
    },
  );

  test('state-changing tool in Plan Mode is blocked', () async {
    final budget = LlmToolBudgetController(baseBudget: 10);
    final cache = <String, CachedToolResult>{};
    final ledger = <LlmToolLedgerEntry>[];
    final controller = ToolLoopController(
      chatService: llm,
      toolBudget: budget,
      readOnlyToolCache: cache,
      toolLedger: ledger,
    );

    final workingMessages = <Map<String, dynamic>>[];
    final settings = await storage.loadAiConnectionSettings();

    final loopResult = await controller.handleToolCalls(
      toolCalls: [
        StreamingToolCall(
          id: 'call_w',
          name: 'sftp_write_text',
          arguments:
              '{"connectionId":"local", "path":"/tmp/test.txt", "content":"hello"}',
        ),
      ],
      visibleToolsByName: {
        'sftp_write_text': AiTool(
          name: 'sftp_write_text',
          description: 'Write text file',
          properties: const {},
          required: const [],
          executionMode: AiToolExecutionMode.stateChanging,
          handler: (args, {approvedWrite = false}) async => '{}',
        ),
      },
      planMode: true, // Plan Mode 激活
      language: AppLanguage.zh,
      apiKey: 'key',
      auditModel: 'audit-model',
      originalUserGoal: 'Goal',
      workingMessages: workingMessages,
      requestToolApproval: (req) async =>
          const AiToolApprovalDecision.approved(),
      onTrace: null,
      cancellationToken: null,
      settings: settings,
      complete: (role, messages, {required thinkingSettings}) async => 'advice',
      classify: (messages) async => '{}',
    );

    expect(loopResult.shouldStop, isFalse);
    expect(workingMessages.last['content'], contains('PLAN MODE is active'));
    expect(loopResult.finalOutcome, AgentFinalOutcome.planModeBlocked);
  });

  test('rejected approval with abort=true stops the loop', () async {
    final budget = LlmToolBudgetController(baseBudget: 10);
    final cache = <String, CachedToolResult>{};
    final ledger = <LlmToolLedgerEntry>[];
    final controller = ToolLoopController(
      chatService: llm,
      toolBudget: budget,
      readOnlyToolCache: cache,
      toolLedger: ledger,
    );

    final workingMessages = <Map<String, dynamic>>[];
    final settings = await storage.loadAiConnectionSettings();
    final traces = <LlmTraceEvent>[];

    final loopResult = await controller.handleToolCalls(
      toolCalls: [
        StreamingToolCall(
          id: 'call_appr',
          name: 'sftp_write_text',
          arguments:
              '{"connectionId":"local", "path":"/tmp/test.txt", "content":"hello"}',
        ),
      ],
      visibleToolsByName: {
        'sftp_write_text': AiTool(
          name: 'sftp_write_text',
          description: 'Write text file',
          properties: const {},
          required: const [],
          executionMode: AiToolExecutionMode.stateChanging,
          handler: (args, {approvedWrite = false}) async => '{}',
        ),
      },
      planMode: false,
      language: AppLanguage.zh,
      apiKey: 'key',
      auditModel: 'audit-model',
      originalUserGoal: 'Goal',
      workingMessages: workingMessages,
      requestToolApproval: (req) async => const AiToolApprovalDecision.rejected(
        abort: true,
        feedback: 'no way',
      ),
      onTrace: (event) => traces.add(event),
      cancellationToken: null,
      settings: settings,
      complete: (role, messages, {required thinkingSettings}) async => 'advice',
      classify: (messages) async => '{}',
    );

    expect(loopResult.shouldStop, isTrue);
    expect(loopResult.stopMessage, contains('Tool action rejected'));
    final hasRejectedMsg = workingMessages.any(
      (m) =>
          m['role'] == 'tool' &&
          m['content'].contains('User rejected the requested tool action'),
    );
    expect(hasRejectedMsg, isTrue);
    expect(loopResult.finalOutcome, AgentFinalOutcome.approvalRejected);
    expect(
      traces.where((event) => event.kind == 'approval').map((event) {
        return jsonDecode(event.content)['status'];
      }),
      containsAll(['requested', 'rejected']),
    );
  });

  test('changed remote target invalidates approval before execution', () async {
    var executed = false;
    final guardedTools = MockToolService(
      onExecute: (name, arguments) async {
        executed = true;
        return '{}';
      },
      mockApprovalRequest: const AiToolApprovalRequest(
        toolName: 'sftp_write_text',
        approvalType: 'remote_write',
        connectionId: 'server-a',
        connectionName: 'Server A',
        command: 'SFTP WRITE /tmp/test.txt',
        reason: 'Remote file write requires user approval.',
      ),
    );
    final guardedLlm = LlmChatService(
      storageService: aiStoragePort(storage),
      toolService: guardedTools,
    );
    final ledger = <LlmToolLedgerEntry>[];
    final controller = ToolLoopController(
      chatService: guardedLlm,
      toolBudget: LlmToolBudgetController(baseBudget: 10),
      readOnlyToolCache: <String, CachedToolResult>{},
      toolLedger: ledger,
    );
    final workingMessages = <Map<String, dynamic>>[];
    final traces = <LlmTraceEvent>[];

    final loopResult = await controller.handleToolCalls(
      toolCalls: [
        StreamingToolCall(
          id: 'call_target_changed',
          name: 'sftp_write_text',
          arguments:
              '{"connectionId":"server-a","path":"/tmp/test.txt","content":"hello"}',
        ),
      ],
      visibleToolsByName: {
        'sftp_write_text': AiTool(
          name: 'sftp_write_text',
          description: 'Write text file',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: (_) async => '{}',
        ),
      },
      planMode: false,
      language: AppLanguage.en,
      apiKey: 'key',
      auditModel: 'audit-model',
      originalUserGoal: 'Write the file',
      workingMessages: workingMessages,
      requestToolApproval: (request) async {
        guardedTools.approvalTargetCurrent = false;
        return const AiToolApprovalDecision.approved();
      },
      onTrace: traces.add,
      cancellationToken: null,
      settings: await storage.loadAiConnectionSettings(),
      complete: (role, messages, {required thinkingSettings}) async => 'advice',
      classify: (messages) async => '{}',
    );

    expect(executed, isFalse);
    expect(loopResult.shouldStop, isTrue);
    expect(loopResult.finalOutcome, AgentFinalOutcome.approvalRejected);
    expect(loopResult.stopMessage, contains('No action was executed'));
    expect(ledger.single.outcome, 'approval_target_changed');
    expect(
      workingMessages.singleWhere(
        (message) => message['role'] == 'tool',
      )['content'],
      contains('approval_target_changed'),
    );
    expect(
      traces.where((event) => event.kind == 'approval').map((event) {
        return jsonDecode(event.content)['status'];
      }),
      containsAll(['requested', 'target_changed']),
    );
  });

  test('budget safety audit rejection triggers postBudgetAudit review', () async {
    // Set budget count so that audit is triggered next call
    final budget = LlmToolBudgetController(baseBudget: 10); // 10 base budget

    // Simulate 15 accepted tool calls to reach the extended limit and force safety audit
    for (var i = 0; i < 15; i++) {
      budget.recordAcceptedToolCall();
    }

    final cache = <String, CachedToolResult>{};
    final ledger = <LlmToolLedgerEntry>[];
    final mockCoordinator = MockMultiAgentCoordinator();
    final localLlm = LlmChatService(
      storageService: aiStoragePort(storage),
      toolService: tools,
      multiAgentCoordinator: mockCoordinator,
    );

    final controller = ToolLoopController(
      chatService: localLlm,
      toolBudget: budget,
      readOnlyToolCache: cache,
      toolLedger: ledger,
    );

    final workingMessages = <Map<String, dynamic>>[];
    final settings = await storage.loadAiConnectionSettings();

    // Tool call: should immediately trigger safety audit because usedCalls (15) >= currentLimit (15)
    final loopResult = await controller.handleToolCalls(
      toolCalls: [
        StreamingToolCall(id: 'call_b', name: 'client_time', arguments: '{}'),
      ],
      visibleToolsByName: {
        'client_time': AiTool(
          name: 'client_time',
          description: 'Get client time',
          properties: const {},
          required: const [],
          executionMode: AiToolExecutionMode.readOnly,
          handler: (args, {approvedWrite = false}) async => '{}',
        ),
      },
      planMode: false,
      language: AppLanguage.zh,
      apiKey: 'key',
      auditModel: 'audit-model',
      originalUserGoal: 'Goal',
      workingMessages: workingMessages,
      requestToolApproval: (req) async => const AiToolApprovalDecision.rejected(
        abort: false,
      ), // User rejects safety audit extension
      onTrace: null,
      cancellationToken: null,
      settings: settings,
      complete: (role, messages, {required thinkingSettings}) async => 'advice',
      classify: (messages) async => '{}',
      planExecutionSnapshot: const PlanExecutionSnapshot(
        phase: PlanExecutionPhase.running,
        steps: [
          AiTodoStep(
            id: 'task-1',
            name: 'Step 1',
            command: 'cmd',
            description: 'desc',
            status: StepStatus.running,
          ),
        ],
        currentStepIndex: 0,
        currentStep: AiTodoStep(
          id: 'task-1',
          name: 'Step 1',
          command: 'cmd',
          description: 'desc',
          status: StepStatus.running,
        ),
        hasFailedStep: false,
        isCompleted: false,
      ),
    );

    expect(loopResult.finalOutcome, AgentFinalOutcome.budgetAuditRejected);
    expect(mockCoordinator.lastTrigger, MultiAgentTrigger.postBudgetAudit);
    expect(
      mockCoordinator.lastPostToolContext,
      contains('Plan execution phase: running'),
    );
    expect(mockCoordinator.lastPostToolContext, contains('Current Plan Step:'));
    expect(mockCoordinator.lastPostToolContext, contains('- taskId: task-1'));
    expect(mockCoordinator.lastPostToolContext, contains('- name: Step 1'));
    expect(mockCoordinator.lastPostToolContext, contains('- command: cmd'));
    expect(mockCoordinator.lastPostToolContext, contains('- status: running'));
  });

  test(
    'post-tool review context includes no active plan snapshot when snapshot is null',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      for (var i = 0; i < 15; i++) {
        budget.recordAcceptedToolCall();
      }

      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final mockCoordinator = MockMultiAgentCoordinator();
      final localLlm = LlmChatService(
        storageService: aiStoragePort(storage),
        toolService: tools,
        multiAgentCoordinator: mockCoordinator,
      );

      final controller = ToolLoopController(
        chatService: localLlm,
        toolBudget: budget,
        readOnlyToolCache: cache,
        toolLedger: ledger,
      );

      final workingMessages = <Map<String, dynamic>>[];
      final settings = await storage.loadAiConnectionSettings();

      final loopResult = await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(id: 'call_b', name: 'client_time', arguments: '{}'),
        ],
        visibleToolsByName: {
          'client_time': AiTool(
            name: 'client_time',
            description: 'Get client time',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.readOnly,
            handler: (args, {approvedWrite = false}) async => '{}',
          ),
        },
        planMode: false,
        language: AppLanguage.zh,
        apiKey: 'key',
        auditModel: 'audit-model',
        originalUserGoal: 'Goal',
        workingMessages: workingMessages,
        requestToolApproval: (req) async =>
            const AiToolApprovalDecision.rejected(abort: false),
        onTrace: null,
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
        planExecutionSnapshot: null,
      );

      expect(loopResult.finalOutcome, AgentFinalOutcome.budgetAuditRejected);
      expect(mockCoordinator.lastTrigger, MultiAgentTrigger.postBudgetAudit);
      expect(
        mockCoordinator.lastPostToolContext,
        contains('No active plan snapshot.'),
      );
    },
  );

  test(
    'unexposed/invisible tool request is blocked early as tool_not_visible',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final controller = ToolLoopController(
        chatService: llm,
        toolBudget: budget,
        readOnlyToolCache: cache,
        toolLedger: ledger,
      );

      final workingMessages = <Map<String, dynamic>>[];
      final settings = await storage.loadAiConnectionSettings();
      final traces = <LlmTraceEvent>[];

      final loopResult = await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call_hid',
            name: 'sftp_write_text',
            arguments:
                '{"connectionId":"local", "path":"/tmp/test.txt", "content":"hello"}',
          ),
        ],
        visibleToolsByName: {
          'client_time': AiTool(
            name: 'client_time',
            description: 'Get client time',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.readOnly,
            handler: (args, {approvedWrite = false}) async => '{}',
          ),
        },
        planMode: false,
        language: AppLanguage.zh,
        apiKey: 'key',
        auditModel: 'audit-model',
        originalUserGoal: 'Goal',
        workingMessages: workingMessages,
        requestToolApproval: (req) async {
          throw StateError(
            'Approval callback should not be called for unexposed tools.',
          );
        },
        onTrace: (event) => traces.add(event),
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.shouldStop, isFalse);
      final toolMessage = workingMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      expect(
        toolMessage['content'],
        contains('Tool is not available in the current context.'),
      );
      final systemMessage = workingMessages.firstWhere(
        (m) => m['role'] == 'system',
      );
      expect(
        systemMessage['content'],
        contains('Do not call hidden or unavailable tools.'),
      );
      expect(ledger.last.outcome, 'tool_not_visible');
      expect(ledger.last.failed, isTrue);
      expect(ledger.last.quality, ToolResultQuality.unsafeBlocked.name);
      final resultTrace = traces.lastWhere(
        (event) =>
            event.kind == 'tool_result' &&
            event.title == 'Tool result: sftp_write_text',
      );
      final resultJson = jsonDecode(resultTrace.content);
      expect(resultJson['outcome'], 'tool_not_visible');
      expect(
        resultJson['resultPreview'],
        contains('Tool is not available in the current context.'),
      );
    },
  );

  test(
    'tool approval unavailable gracefully blocks with approvalUnavailable outcome',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final controller = ToolLoopController(
        chatService: llm,
        toolBudget: budget,
        readOnlyToolCache: cache,
        toolLedger: ledger,
      );

      final workingMessages = <Map<String, dynamic>>[];
      final settings = await storage.loadAiConnectionSettings();

      final loopResult = await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call_no_appr',
            name: 'sftp_write_text',
            arguments:
                '{"connectionId":"local", "path":"/tmp/test.txt", "content":"hello"}',
          ),
        ],
        visibleToolsByName: {
          'sftp_write_text': AiTool(
            name: 'sftp_write_text',
            description: 'Write text file',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.stateChanging,
            handler: (args, {approvedWrite = false}) async => '{}',
          ),
        },
        planMode: false,
        language: AppLanguage.zh,
        apiKey: 'key',
        auditModel: 'audit-model',
        originalUserGoal: 'Goal',
        workingMessages: workingMessages,
        requestToolApproval: null,
        onTrace: null,
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.shouldStop, isTrue);
      expect(loopResult.finalOutcome, AgentFinalOutcome.approvalUnavailable);
      expect(loopResult.stopMessage, contains('approval is unavailable'));
      final toolMessage = workingMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      expect(toolMessage['content'], contains('no approval UI is available'));
      expect(ledger.last.outcome, 'approval_unavailable');
    },
  );

  test(
    'post-tool review still runs when multiAgent is disabled but postToolReview is enabled',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final mockCoordinator = MockMultiAgentCoordinator();
      final localLlm = LlmChatService(
        storageService: aiStoragePort(storage),
        toolService: tools,
        multiAgentCoordinator: mockCoordinator,
      );

      final controller = ToolLoopController(
        chatService: localLlm,
        toolBudget: budget,
        readOnlyToolCache: cache,
        toolLedger: ledger,
      );

      final workingMessages = <Map<String, dynamic>>[];
      final settings = (await storage.loadAiConnectionSettings()).copyWith(
        multiAgentEnabled: false,
        postToolReviewEnabled: true,
      );

      final loopResult = await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call_no_appr',
            name: 'sftp_write_text',
            arguments:
                '{"connectionId":"local", "path":"/tmp/test.txt", "content":"hello"}',
          ),
        ],
        visibleToolsByName: {
          'sftp_write_text': AiTool(
            name: 'sftp_write_text',
            description: 'Write text file',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.stateChanging,
            handler: (args, {approvedWrite = false}) async => '{}',
          ),
        },
        planMode: false,
        language: AppLanguage.zh,
        apiKey: 'key',
        auditModel: 'audit-model',
        originalUserGoal: 'Goal',
        workingMessages: workingMessages,
        requestToolApproval: null,
        onTrace: null,
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.shouldStop, isTrue);
      expect(loopResult.finalOutcome, AgentFinalOutcome.approvalUnavailable);
      expect(mockCoordinator.lastTrigger, MultiAgentTrigger.postToolFailure);
      expect(workingMessages.last['content'], contains('mock memory'));
    },
  );
}
