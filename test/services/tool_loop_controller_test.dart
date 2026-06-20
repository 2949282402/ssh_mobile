import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/performance_monitor_tool_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/multi_agent_coordinator.dart';
import 'package:ssh_mobile/services/agent/plan_execution_controller.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';

void main() {
  group('ToolLoopController integration tests', () {
    late StorageService storage;
    late AiToolService tools;
    late LlmChatService llm;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      storage = StorageService();
      await storage.init();

      await storage.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );

      final ssh = SshService(storage);
      final sftp = SftpService(storage);
      final diagnostics = ServerDiagnosticsService(
        storageService: storage,
        sshService: ssh,
      );
      final monitor = PerformanceMonitorService(ssh, storage);
      tools = AiToolService(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
        serverDiagnosticsService: diagnostics,
        performanceMonitorToolService: PerformanceMonitorToolService(monitor),
      );

      llm = LlmChatService(
        storageService: storage,
        toolService: tools,
      );
    });

    tearDown(() {
      storage.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

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
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.shouldStop, isFalse);
      expect(controller.cacheHitCount, 1);
      expect(workingMessages.length, 1);
      expect(workingMessages.first['content'], contains('2026-06-17 12:00:00'));
    });

    test('repeated read-only call reaches loop guard and disables tools',
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
        ledger.add(LlmToolLedgerEntry(
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
        ));
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
      final hasBlockedMsg = workingMessages.any((m) =>
          m['role'] == 'tool' &&
          m['content'].contains('Deterministic loop guard blocked'));
      expect(hasBlockedMsg, isTrue);
      expect(loopResult.finalOutcome, AgentFinalOutcome.loopGuardBlocked);
    });

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
                  '{"connectionId":"local", "path":"/tmp/test.txt", "content":"hello"}'),
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
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
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

      final loopResult = await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
              id: 'call_appr',
              name: 'sftp_write_text',
              arguments:
                  '{"connectionId":"local", "path":"/tmp/test.txt", "content":"hello"}'),
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
        requestToolApproval: (req) async =>
            const AiToolApprovalDecision.rejected(
                abort: true, feedback: 'no way'),
        onTrace: null,
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.shouldStop, isTrue);
      expect(loopResult.stopMessage, contains('Tool action rejected'));
      final hasRejectedMsg = workingMessages.any((m) =>
          m['role'] == 'tool' &&
          m['content'].contains('User rejected the requested tool action'));
      expect(hasRejectedMsg, isTrue);
      expect(loopResult.finalOutcome, AgentFinalOutcome.approvalRejected);
    });

    test('budget safety audit rejection triggers postBudgetAudit review',
        () async {
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
        requestToolApproval: (req) async =>
            const AiToolApprovalDecision.rejected(
                abort: false), // User rejects safety audit extension
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
                status: StepStatus.running),
          ],
          currentStepIndex: 0,
          currentStep: AiTodoStep(
              id: 'task-1',
              name: 'Step 1',
              command: 'cmd',
              description: 'desc',
              status: StepStatus.running),
          hasFailedStep: false,
          isCompleted: false,
        ),
      );

      expect(loopResult.finalOutcome, AgentFinalOutcome.budgetAuditRejected);
      expect(mockCoordinator.lastTrigger, MultiAgentTrigger.postBudgetAudit);
      expect(mockCoordinator.lastPostToolContext,
          contains('Plan execution phase: running'));
      expect(
          mockCoordinator.lastPostToolContext, contains('Current Plan Step:'));
      expect(mockCoordinator.lastPostToolContext, contains('- taskId: task-1'));
      expect(mockCoordinator.lastPostToolContext, contains('- name: Step 1'));
      expect(mockCoordinator.lastPostToolContext, contains('- command: cmd'));
      expect(
          mockCoordinator.lastPostToolContext, contains('- status: running'));
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
      expect(mockCoordinator.lastPostToolContext,
          contains('No active plan snapshot.'));
    });

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
              'Approval callback should not be called for unexposed tools.');
        },
        onTrace: null,
        cancellationToken: null,
        settings: settings,
        complete: (role, messages, {required thinkingSettings}) async =>
            'advice',
        classify: (messages) async => '{}',
      );

      expect(loopResult.shouldStop, isFalse);
      final toolMessage =
          workingMessages.firstWhere((m) => m['role'] == 'tool');
      expect(toolMessage['content'],
          contains('Tool is not available in the current context.'));
      final systemMessage =
          workingMessages.firstWhere((m) => m['role'] == 'system');
      expect(systemMessage['content'],
          contains('Do not call hidden or unavailable tools.'));
      expect(ledger.last.outcome, 'tool_not_visible');
      expect(ledger.last.failed, isTrue);
      expect(ledger.last.quality, ToolResultQuality.unsafeBlocked.name);
    });

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
      final toolMessage =
          workingMessages.firstWhere((m) => m['role'] == 'tool');
      expect(toolMessage['content'], contains('no approval UI is available'));
      expect(ledger.last.outcome, 'approval_unavailable');
    });

    test(
        'post-tool review still runs when multiAgent is disabled but postToolReview is enabled',
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
    });

    test('post-tool review is skipped when postToolReviewEnabled is false',
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
      final hasSkipTrace = events.any((ev) =>
          ev.kind == 'multi_agent_post_tool_review_skipped' &&
          ev.content.contains('postToolReviewEnabled=false'));
      expect(hasSkipTrace, isTrue);
    });

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
      final toolMessage =
          workingMessages.firstWhere((m) => m['role'] == 'tool');
      final content = jsonDecode(toolMessage['content']);
      expect(content['code'], 'task_update_required');
      expect(content['taskId'], 'task-1');
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.planStepNeedsUpdate.name);
    });

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
      final toolMessage =
          workingMessages.firstWhere((m) => m['role'] == 'tool');
      expect(toolMessage['content'], contains('success'));
      expect(ledger.last.outcome, 'success');
      expect(ledger.last.quality, ToolResultQuality.useful.name);
    });

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
      final toolMessage =
          workingMessages.firstWhere((m) => m['role'] == 'tool');
      final content = jsonDecode(toolMessage['content']);
      expect(content['code'], 'plan_execution_blocked');
      expect(content['reason'], 'A preceding step has failed.');
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.unsafeBlocked.name);
    });

    test('read-only remote tool is blocked when current step is pending',
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
      final toolMessage =
          workingMessages.firstWhere((m) => m['role'] == 'tool');
      final content = jsonDecode(toolMessage['content']);
      expect(content['code'], 'task_update_required');
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.planStepNeedsUpdate.name);
    });

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
      expect(executed, isTrue);
      final toolMessage =
          workingMessages.firstWhere((m) => m['role'] == 'tool');
      expect(toolMessage['content'], contains('2026'));
      expect(ledger.last.outcome, 'success');
      expect(ledger.last.quality, ToolResultQuality.useful.name);
    });

    test('connection_required hint is not confused with task_update_required',
        () async {
      final hint1 = ToolResultClassifier.getSystemHint('sftp_write_text',
          ToolResultQuality.planStepNeedsUpdate, AppLanguage.zh);
      final hint2 = ToolResultClassifier.getSystemHint('sftp_write_text',
          ToolResultQuality.connectionRequired, AppLanguage.zh);

      expect(hint1, contains('client_task_update'));
      expect(hint2, contains('选择服务器连接'));
    });

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
    });
  });
}

class MockMultiAgentCoordinator implements MultiAgentCoordinatorAdapter {
  MultiAgentTrigger? lastTrigger;
  String? lastPostToolContext;

  @override
  Future<MultiAgentRunResult?> run({
    required List<Map<String, dynamic>> messages,
    required bool enabled,
    required int maxAgents,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    void Function()? checkCancelled,
    AppLanguage language = AppLanguage.zh,
    String? plannerPrompt,
    String? operatorPrompt,
    String? explorePrompt,
    String? reviewerPrompt,
    String? summarizerPrompt,
    String? coordinatorPrompt,
    bool planMode = false,
    MultiAgentTrigger trigger = MultiAgentTrigger.preflight,
    String? postToolContext,
  }) async {
    lastTrigger = trigger;
    lastPostToolContext = postToolContext;
    return const MultiAgentRunResult(
      memoryContent: 'mock memory',
      traceContent: 'mock trace',
      agentCount: 2,
    );
  }
}

class MockToolService implements AiToolExecutor {
  final Future<String> Function(String name, Map<String, dynamic> arguments)
      onExecute;
  final AiToolApprovalRequest? mockApprovalRequest;

  MockToolService({
    required this.onExecute,
    this.mockApprovalRequest,
  });

  @override
  Future<List<AiTool>> tools() async => [];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async => [];

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return mockApprovalRequest;
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    return onExecute(name, arguments);
  }

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    return const AiCommandReview.readOnly();
  }
}
