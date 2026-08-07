part of 'tool_loop_controller_test.dart';

void _registerToolLoopGateTests() {
  test(
    'post-tool review is skipped when postToolReviewEnabled is false',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final mockCoordinator = MockMultiAgentCoordinator();
      final localLlm = LlmChatService(
        storageService: storage,
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
        multiAgentEnabled: true,
        postToolReviewEnabled: false,
      );

      final events = <LlmTraceEvent>[];

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
        onTrace: (ev) => events.add(ev),
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.shouldStop, isTrue);
      expect(loopResult.finalOutcome, AgentFinalOutcome.approvalUnavailable);
      expect(mockCoordinator.lastTrigger, isNull);
      final hasSkipTrace = events.any(
        (ev) =>
            ev.kind == 'multi_agent_post_tool_review_skipped' &&
            ev.content.contains('postToolReviewEnabled=false'),
      );
      expect(hasSkipTrace, isTrue);
    },
  );

  test(
    'remote mutating tool call is blocked by gate when current step is pending',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      bool executed = false;
      final mockTools = MockToolService(
        onExecute: (name, args) async {
          executed = true;
          return '{}';
        },
      );
      final localLlm = LlmChatService(
        storageService: storage,
        toolService: mockTools,
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
          StreamingToolCall(
            id: 'call_blocked_pending',
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
            handler: (args) async {
              executed = true;
              return '{}';
            },
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
        planExecutionSnapshot: const PlanExecutionSnapshot(
          phase: PlanExecutionPhase.pending,
          steps: [
            AiTodoStep(
              id: 'task-1',
              name: 'Step 1',
              command: 'cmd',
              description: 'desc',
              status: StepStatus.pending,
            ),
          ],
          currentStepIndex: 0,
          currentStep: AiTodoStep(
            id: 'task-1',
            name: 'Step 1',
            command: 'cmd',
            description: 'desc',
            status: StepStatus.pending,
          ),
          hasFailedStep: false,
          isCompleted: false,
        ),
      );

      expect(loopResult.shouldStop, isFalse);
      expect(executed, isFalse);
      final toolMessage = workingMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      final content = jsonDecode(toolMessage['content']);
      expect(content['code'], 'task_update_required');
      expect(content['taskId'], 'task-1');
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.planStepNeedsUpdate.name);
    },
  );

  test(
    'client_task_update refreshes in-memory snapshot before next remote tool',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      final executed = <String>[];
      final mockTools = MockToolService(
        onExecute: (name, args) async {
          executed.add(name);
          if (name == 'client_task_update') {
            return '{"status":"success","taskId":"task-1","newStatus":"running"}';
          }
          return '{"success":true}';
        },
      );
      final localLlm = LlmChatService(
        storageService: storage,
        toolService: mockTools,
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
          StreamingToolCall(
            id: 'call_task_running',
            name: 'client_task_update',
            arguments: '{"taskId":"task-1","status":"running"}',
          ),
          StreamingToolCall(
            id: 'call_remote_after_running',
            name: 'detect_os',
            arguments: '{"connectionId":"server-1"}',
          ),
        ],
        visibleToolsByName: {
          'client_task_update': AiTool(
            name: 'client_task_update',
            description: 'Update task',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.executionOnly,
            handler: (args) async => '{}',
          ),
          'detect_os': AiTool(
            name: 'detect_os',
            description: 'Detect OS',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.readOnly,
            handler: (args) async => '{}',
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
        planExecutionSnapshot: const PlanExecutionSnapshot(
          phase: PlanExecutionPhase.pending,
          steps: [
            AiTodoStep(
              id: 'task-1',
              name: 'Step 1',
              command: 'cmd',
              description: 'desc',
              status: StepStatus.pending,
            ),
          ],
          currentStepIndex: 0,
          currentStep: AiTodoStep(
            id: 'task-1',
            name: 'Step 1',
            command: 'cmd',
            description: 'desc',
            status: StepStatus.pending,
          ),
          hasFailedStep: false,
          isCompleted: false,
        ),
      );

      expect(loopResult.shouldStop, isFalse);
      expect(executed, ['client_task_update', 'detect_os']);
      expect(
        loopResult.planExecutionSnapshot?.currentStep?.status,
        StepStatus.running,
      );
      expect(ledger.map((entry) => entry.outcome), everyElement('success'));
    },
  );

  test(
    'remote mutating tool call is allowed by gate when current step is running',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      bool executed = false;
      final mockTools = MockToolService(
        mockApprovalRequest: const AiToolApprovalRequest(
          toolName: 'sftp_write_text',
          approvalType: 'sftp_write',
          connectionId: 'local',
          connectionName: 'Local',
          command: 'write text',
          reason: 'write',
        ),
        onExecute: (name, args) async {
          executed = true;
          return '{"success":true}';
        },
      );
      final localLlm = LlmChatService(
        storageService: storage,
        toolService: mockTools,
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
          StreamingToolCall(
            id: 'call_allowed_running',
            name: 'sftp_write_text',
            arguments: '{"connectionId":"local", "taskId":"task-1"}',
          ),
        ],
        visibleToolsByName: {
          'sftp_write_text': AiTool(
            name: 'sftp_write_text',
            description: 'Write text file',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.stateChanging,
            handler: (args) async {
              executed = true;
              return '{"success":true}';
            },
          ),
        },
        planMode: false,
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
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
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

      expect(loopResult.shouldStop, isFalse);
      expect(executed, isTrue);
      final toolMessage = workingMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      expect(toolMessage['content'], contains('success'));
      expect(ledger.last.outcome, 'success');
      expect(ledger.last.quality, ToolResultQuality.useful.name);
    },
  );

  test(
    'remote mutating tool call is blocked by gate when a preceding step is failed',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      bool executed = false;
      final mockTools = MockToolService(
        onExecute: (name, args) async {
          executed = true;
          return '{}';
        },
      );
      final localLlm = LlmChatService(
        storageService: storage,
        toolService: mockTools,
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
          StreamingToolCall(
            id: 'call_blocked_failed',
            name: 'sftp_write_text',
            arguments: '{"connectionId":"local"}',
          ),
        ],
        visibleToolsByName: {
          'sftp_write_text': AiTool(
            name: 'sftp_write_text',
            description: 'Write text file',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.stateChanging,
            handler: (args) async {
              executed = true;
              return '{}';
            },
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
        planExecutionSnapshot: const PlanExecutionSnapshot(
          phase: PlanExecutionPhase.blockedByFailure,
          steps: [
            AiTodoStep(
              id: 'task-1',
              name: 'Step 1',
              command: 'cmd',
              description: 'desc',
              status: StepStatus.failed,
            ),
            AiTodoStep(
              id: 'task-2',
              name: 'Step 2',
              command: 'cmd2',
              description: 'desc',
              status: StepStatus.pending,
            ),
          ],
          currentStepIndex: 1,
          currentStep: AiTodoStep(
            id: 'task-2',
            name: 'Step 2',
            command: 'cmd2',
            description: 'desc',
            status: StepStatus.pending,
          ),
          hasFailedStep: true,
          isCompleted: false,
        ),
      );

      expect(loopResult.shouldStop, isFalse);
      expect(executed, isFalse);
      final toolMessage = workingMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      final content = jsonDecode(toolMessage['content']);
      expect(content['code'], 'plan_execution_blocked');
      expect(content['reason'], 'A preceding step has failed.');
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.unsafeBlocked.name);
    },
  );

  test(
    'read-only remote tool is blocked when current step is pending',
    () async {
      final budget = LlmToolBudgetController(baseBudget: 10);
      final cache = <String, CachedToolResult>{};
      final ledger = <LlmToolLedgerEntry>[];
      bool executed = false;
      final mockTools = MockToolService(
        onExecute: (name, args) async {
          executed = true;
          return '{}';
        },
      );
      final localLlm = LlmChatService(
        storageService: storage,
        toolService: mockTools,
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
          StreamingToolCall(
            id: 'call_blocked_read_only',
            name: 'detect_os',
            arguments: '{"connectionId":"local"}',
          ),
        ],
        visibleToolsByName: {
          'detect_os': AiTool(
            name: 'detect_os',
            description: 'Detect server OS',
            properties: const {},
            required: const [],
            executionMode: AiToolExecutionMode.readOnly,
            handler: (args) async {
              executed = true;
              return '{}';
            },
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
        planExecutionSnapshot: const PlanExecutionSnapshot(
          phase: PlanExecutionPhase.pending,
          steps: [
            AiTodoStep(
              id: 'task-1',
              name: 'Step 1',
              command: 'cmd',
              description: 'desc',
              status: StepStatus.pending,
            ),
          ],
          currentStepIndex: 0,
          currentStep: AiTodoStep(
            id: 'task-1',
            name: 'Step 1',
            command: 'cmd',
            description: 'desc',
            status: StepStatus.pending,
          ),
          hasFailedStep: false,
          isCompleted: false,
        ),
      );

      expect(loopResult.shouldStop, isFalse);
      expect(executed, isFalse);
      final toolMessage = workingMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      final content = jsonDecode(toolMessage['content']);
      expect(content['code'], 'task_update_required');
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.planStepNeedsUpdate.name);
    },
  );

  test('client read-only tool bypasses execution gate', () async {
    final budget = LlmToolBudgetController(baseBudget: 10);
    final cache = <String, CachedToolResult>{};
    final ledger = <LlmToolLedgerEntry>[];
    bool executed = false;
    final mockTools = MockToolService(
      onExecute: (name, args) async {
        executed = true;
        return '{"time":"2026"}';
      },
    );
    final localLlm = LlmChatService(
      storageService: storage,
      toolService: mockTools,
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
        StreamingToolCall(
          id: 'call_client_bypass',
          name: 'client_time',
          arguments: '{}',
        ),
      ],
      visibleToolsByName: {
        'client_time': AiTool(
          name: 'client_time',
          description: 'Get client time',
          properties: const {},
          required: const [],
          executionMode: AiToolExecutionMode.readOnly,
          handler: (args) async {
            executed = true;
            return '{"time":"2026"}';
          },
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
      planExecutionSnapshot: const PlanExecutionSnapshot(
        phase: PlanExecutionPhase.pending,
        steps: [
          AiTodoStep(
            id: 'task-1',
            name: 'Step 1',
            command: 'cmd',
            description: 'desc',
            status: StepStatus.pending,
          ),
        ],
        currentStepIndex: 0,
        currentStep: AiTodoStep(
          id: 'task-1',
          name: 'Step 1',
          command: 'cmd',
          description: 'desc',
          status: StepStatus.pending,
        ),
        hasFailedStep: false,
        isCompleted: false,
      ),
    );

    expect(loopResult.shouldStop, isFalse);
    expect(executed, isTrue);
    final toolMessage = workingMessages.firstWhere((m) => m['role'] == 'tool');
    expect(toolMessage['content'], contains('2026'));
    expect(ledger.last.outcome, 'success');
    expect(ledger.last.quality, ToolResultQuality.useful.name);
  });

  test(
    'connection_required hint is not confused with task_update_required',
    () async {
      final hint1 = ToolResultClassifier.getSystemHint(
        'sftp_write_text',
        ToolResultQuality.planStepNeedsUpdate,
        AppLanguage.zh,
      );
      final hint2 = ToolResultClassifier.getSystemHint(
        'sftp_write_text',
        ToolResultQuality.connectionRequired,
        AppLanguage.zh,
      );

      expect(hint1, contains('client_task_update'));
      expect(hint2, contains('选择服务器连接'));
    },
  );

  test('gate block trace includes step scoped metadata', () async {
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

    await controller.handleToolCalls(
      toolCalls: [
        StreamingToolCall(
          id: 'call_blocked_trace',
          name: 'detect_os',
          arguments: '{"connectionId":"local"}',
        ),
      ],
      visibleToolsByName: {
        'detect_os': AiTool(
          name: 'detect_os',
          description: 'Detect OS',
          properties: const {},
          required: const [],
          executionMode: AiToolExecutionMode.readOnly,
          handler: (args) async => '{}',
        ),
      },
      planMode: false,
      language: AppLanguage.zh,
      apiKey: 'key',
      auditModel: 'audit-model',
      originalUserGoal: 'Goal',
      workingMessages: workingMessages,
      requestToolApproval: null,
      onTrace: (ev) => traces.add(ev),
      cancellationToken: null,
      settings: settings,
      complete: (role, messages, {required thinkingSettings}) async => 'advice',
      classify: (messages) async => '{}',
      planExecutionSnapshot: const PlanExecutionSnapshot(
        phase: PlanExecutionPhase.pending,
        steps: [
          AiTodoStep(
            id: 'task-1',
            name: 'Step 1',
            command: 'cmd',
            description: 'desc',
            status: StepStatus.pending,
          ),
        ],
        currentStepIndex: 0,
        currentStep: AiTodoStep(
          id: 'task-1',
          name: 'Step 1',
          command: 'cmd',
          description: 'desc',
          status: StepStatus.pending,
        ),
        hasFailedStep: false,
        isCompleted: false,
      ),
    );

    final blockTrace = traces.firstWhere((ev) => ev.kind == 'tool_blocked');
    expect(blockTrace.content, contains('"stepScoped": true'));
    expect(blockTrace.content, contains('"executionMode": "readOnly"'));
    expect(blockTrace.content, contains('"reason": "task_update_required"'));
    expect(blockTrace.content, contains('"currentStepStatus": "pending"'));
    final resultTrace = traces.lastWhere((ev) => ev.kind == 'tool_result');
    final resultJson = jsonDecode(resultTrace.content);
    expect(resultJson['outcome'], 'plan_execution_blocked');
    expect(
      resultJson['resultPreview'],
      contains('Tool call blocked by plan execution gate.'),
    );
  });
}
