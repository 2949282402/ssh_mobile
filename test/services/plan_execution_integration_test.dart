import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/agent/plan_execution_controller.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Plan execution step-by-step integration tests', () {
    late StorageService storage;
    late _MockToolService mockTools;
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
    });

    tearDown(() {
      storage.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    test('sequential step execution, failed blockage, and skip recovery flow',
        () async {
      // 1. Create a chat record with an approved plan containing 2 pending steps
      final now = DateTime.now();
      final approvedPlanRef = AiApprovedPlanRef(
        assistantCreatedAt: now,
        approvedAt: now,
      );

      var chat = AiChatRecord(
        id: 'chat-1',
        title: 'Integration Test Chat',
        model: 'demo-model',
        messages: [
          AiChatMessageRecord(
            role: 'assistant',
            text: 'Here is the plan...',
            createdAt: now,
            todoSteps: [
              AiTodoStep(
                id: 'task-1',
                name: 'Step 1',
                command: 'echo first',
                description: 'First step description',
                status: StepStatus.pending,
                connectionId: 'server-1',
              ),
              AiTodoStep(
                id: 'task-2',
                name: 'Step 2',
                command: 'echo second',
                description: 'Second step description',
                status: StepStatus.pending,
                connectionId: 'server-1',
              ),
            ],
          ),
        ],
        createdAt: now,
        updatedAt: now,
        planMode: false,
        approvedPlan: approvedPlanRef,
      );
      await storage.saveAiChat(chat);

      // 2. Initialize mock tools service and chat service
      bool executedFirst = false;
      bool executedSecond = false;

      mockTools = _MockToolService(
        mockApprovalRequest: const AiToolApprovalRequest(
          toolName: 'sftp_write_text',
          approvalType: 'sftp_write',
          connectionId: 'server-1',
          connectionName: 'Server 1',
          command: 'write text',
          reason: 'write',
        ),
        onExecute: (name, args) async {
          if (name == 'sftp_write_text') {
            final path = args['path'] as String?;
            if (path == '/tmp/first.txt') {
              executedFirst = true;
              return '{"success":true}';
            }
            if (path == '/tmp/second.txt') {
              executedSecond = true;
              return '{"success":true}';
            }
          }
          return '{}';
        },
      );

      llm = LlmChatService(
        storageService: storage,
        toolService: mockTools,
      );

      // We need to fetch visible tools
      final visibleTools = <String, AiTool>{
        'sftp_write_text': AiTool(
          name: 'sftp_write_text',
          description: 'Write text file',
          properties: const {},
          required: const [],
          executionMode: AiToolExecutionMode.stateChanging,
          handler: (args) async => '{}',
        ),
      };

      // 3. Initialize loop controller
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

      // Ensure that clientWebViewSessionId of toolService points to our chat-1
      // We can construct AiToolService to override it, or since our mockTools is not AiToolService,
      // the controller fallback will use the passed planExecutionSnapshot argument.
      // So we will pass the snapshot computed from chat database.
      var latestChat =
          (await storage.loadAiChats()).firstWhere((c) => c.id == 'chat-1');
      var snap = const PlanExecutionController()
          .snapshot(latestChat.messages.last.todoSteps);

      // --- PHASE 3.1: Execute step 1 without marking it running first -> should be BLOCKED ---
      await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call-1',
            name: 'sftp_write_text',
            arguments: '{"connectionId":"server-1", "path":"/tmp/first.txt"}',
          ),
        ],
        visibleToolsByName: visibleTools,
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
        planExecutionSnapshot: snap,
      );

      expect(executedFirst, isFalse);
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.planStepNeedsUpdate.name);

      // --- PHASE 3.1b: Execute read-only remote tool (detect_os) without marking it running first -> should be BLOCKED ---
      await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call-1b',
            name: 'detect_os',
            arguments: '{"connectionId":"server-1"}',
          ),
        ],
        visibleToolsByName: {
          ...visibleTools,
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
        planExecutionSnapshot: snap,
      );

      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.planStepNeedsUpdate.name);

      // --- PHASE 3.2: Update step 1 to running manually in database, then execute -> should SUCCEED ---
      final steps = [...latestChat.messages.last.todoSteps];
      steps[0] = steps[0].copyWith(status: StepStatus.running);
      latestChat = latestChat.copyWith(
        messages: [
          latestChat.messages.last.copyWith(todoSteps: steps),
        ],
      );
      await storage.saveAiChat(latestChat);
      snap = const PlanExecutionController()
          .snapshot(latestChat.messages.last.todoSteps);

      await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call-2',
            name: 'sftp_write_text',
            arguments: '{"connectionId":"server-1", "path":"/tmp/first.txt"}',
          ),
        ],
        visibleToolsByName: visibleTools,
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
        planExecutionSnapshot: snap,
      );

      expect(executedFirst, isTrue);
      expect(ledger.last.outcome, 'success');

      // --- PHASE 3.3: Mark step 1 as failed. Try to execute step 2 -> should be BLOCKED by failed previous step ---
      steps[0] = steps[0].copyWith(status: StepStatus.failed);
      latestChat = latestChat.copyWith(
        messages: [
          latestChat.messages.last.copyWith(todoSteps: steps),
        ],
      );
      await storage.saveAiChat(latestChat);
      snap = const PlanExecutionController()
          .snapshot(latestChat.messages.last.todoSteps);

      await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call-3',
            name: 'sftp_write_text',
            arguments: '{"connectionId":"server-1", "path":"/tmp/second.txt"}',
          ),
        ],
        visibleToolsByName: visibleTools,
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
        planExecutionSnapshot: snap,
      );

      expect(executedSecond, isFalse);
      expect(ledger.last.outcome, 'plan_execution_blocked');
      expect(ledger.last.quality, ToolResultQuality.unsafeBlocked.name);

      // --- PHASE 3.4: Skip the failed step 1, mark step 2 as running, then execute step 2 -> should SUCCEED ---
      steps[0] = steps[0].copyWith(
          status: StepStatus.skipped, stdout: 'Skipped: manual bypass');
      steps[1] = steps[1].copyWith(status: StepStatus.running);
      latestChat = latestChat.copyWith(
        messages: [
          latestChat.messages.last.copyWith(todoSteps: steps),
        ],
      );
      await storage.saveAiChat(latestChat);
      snap = const PlanExecutionController()
          .snapshot(latestChat.messages.last.todoSteps);

      await controller.handleToolCalls(
        toolCalls: [
          StreamingToolCall(
            id: 'call-4',
            name: 'sftp_write_text',
            arguments: '{"connectionId":"server-1", "path":"/tmp/second.txt"}',
          ),
        ],
        visibleToolsByName: visibleTools,
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
        planExecutionSnapshot: snap,
      );

      expect(executedSecond, isTrue);
      expect(ledger.last.outcome, 'success');
    });
  });
}

class _MockToolService implements AiToolExecutor {
  final Future<String> Function(String name, Map<String, dynamic> arguments)
      onExecute;
  final AiToolApprovalRequest? mockApprovalRequest;

  _MockToolService({
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
