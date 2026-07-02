import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/llm_runtime/llm_runtime_types.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/performance_monitor_tool_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  group('LlmChatService token estimates', () {
    test('counts ASCII in four-character chunks and non-ASCII per rune', () {
      expect(LlmChatService.estimateTextTokens(''), 0);
      expect(LlmChatService.estimateTextTokens('abcd'), 1);
      expect(LlmChatService.estimateTextTokens('abcde'), 2);
      expect(LlmChatService.estimateTextTokens('\u4e2d\u6587'), 2);
      expect(LlmChatService.estimateTextTokens('abcd\u4e2d\u6587'), 3);
    });

    test('adds per-message overhead', () {
      final tokens = LlmChatService.estimateMessagesTokens([
        {'role': 'user', 'content': 'abcd'},
        {'role': 'assistant', 'content': '\u4e2d\u6587'},
      ]);

      expect(tokens, 4 + 1 + 1 + 4 + 3 + 2);
    });
  });

  group('OpenAI-compatible URL resolution', () {
    test('appends chat completion path to a versioned base URL', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/',
          '/chat/completions',
        ),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('switches between full chat and models endpoints', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/chat/completions',
          '/models',
        ),
        'https://api.example.com/v1/models',
      );
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/models',
          '/chat/completions',
        ),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('drops accidental query strings and fragments', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1?debug=1#frag',
          '/models',
        ),
        'https://api.example.com/v1/models',
      );
    });
  });

  test('recognizes provider errors for unsupported function tools', () {
    expect(
      LlmChatService.looksLikeToolUnsupportedError(
        '{"error":"tool_choice is not supported"}',
      ),
      isTrue,
    );
    expect(
      LlmChatService.looksLikeToolUnsupportedError('invalid model'),
      isFalse,
    );
  });

  group('AgentLoopGuard', () {
    test('balanced uses 16 rounds and repeatable +8 approvals', () {
      final guard = AgentLoopGuard(mode: AiAgentLoopMode.balanced);

      expect(guard.modelRoundLimit, 16);
      expect(guard.extensionSize, 8);
      expect(guard.shouldRequestApproval(toolsEnabled: true), isFalse);

      for (var i = 0; i < 16; i++) {
        guard.recordModelRoundStarted();
      }

      expect(guard.modelRoundsUsed, 16);
      expect(guard.shouldRequestApproval(toolsEnabled: true), isTrue);
      expect(guard.approveExtension(), 24);
      expect(guard.loopExtensionCount, 1);

      for (var i = 0; i < 8; i++) {
        guard.recordModelRoundStarted();
      }

      expect(guard.shouldRequestApproval(toolsEnabled: true), isTrue);
      expect(guard.approveExtension(), 32);
      expect(guard.loopExtensionCount, 2);
    });

    test('deep uses 24 rounds and +12 approval extension', () {
      final guard = AgentLoopGuard(mode: AiAgentLoopMode.deep);

      expect(guard.modelRoundLimit, 24);
      expect(guard.extensionSize, 12);
      for (var i = 0; i < 24; i++) {
        guard.recordModelRoundStarted();
      }

      expect(guard.shouldRequestApproval(toolsEnabled: true), isTrue);
      expect(guard.approveExtension(), 36);
    });

    test('unlimited has no round approval limit', () {
      final guard = AgentLoopGuard(mode: AiAgentLoopMode.unlimited);

      expect(guard.modelRoundLimit, isNull);
      expect(guard.isUnlimited, isTrue);
      for (var i = 0; i < 100; i++) {
        guard.recordModelRoundStarted();
      }

      expect(guard.shouldRequestApproval(toolsEnabled: true), isFalse);
      expect(guard.shouldRequestApproval(toolsEnabled: false), isFalse);
    });
  });

  group('LlmChatService cancellation & compression', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('LlmCancellationToken propagates cancellation immediately', () {
      final token = LlmCancellationToken();
      expect(token.isCancelled, isFalse);

      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(() => token.throwIfCancelled(),
          throwsA(isA<LlmCancelledException>()));
    });

    test(
        'stream with cancelled token during compression throws LlmCancelledException',
        () async {
      final storage = StorageService();
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
      final tools = AiToolService(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
        serverDiagnosticsService: diagnostics,
        performanceMonitorToolService: PerformanceMonitorToolService(monitor),
      );

      final llm = LlmChatService(
        storageService: storage,
        toolService: tools,
      );

      final token = LlmCancellationToken();
      token.cancel();

      final messages = [
        {'role': 'user', 'content': 'hello'},
      ];

      expect(
        () => llm
            .stream(
              messages: messages,
              cancellationToken: token,
              forceContextCompression: true,
            )
            .toList(),
        throwsA(isA<LlmCancelledException>()),
      );

      storage.dispose();
    });
  });

  group('LlmToolBudgetController', () {
    test('auto-extends at the default budget and audits the next block', () {
      final controller = LlmToolBudgetController(baseBudget: 20);

      for (var i = 0; i < 19; i++) {
        expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
        expect(controller.recordAcceptedToolCall(), isNull);
      }

      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
      final autoExtension = controller.recordAcceptedToolCall();
      expect(autoExtension, isNotNull);
      expect(autoExtension!.type, 'auto_extend');
      expect(autoExtension.previousLimit, 20);
      expect(autoExtension.newLimit, 30);
      expect(controller.usedCalls, 20);
      expect(controller.currentLimit, 30);

      for (var i = 0; i < 10; i++) {
        expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
        expect(controller.recordAcceptedToolCall(), isNull);
      }

      expect(controller.usedCalls, 30);
      expect(controller.checkBeforeToolCall().requiresAudit, isTrue);
    });

    test('approved audits keep extending in half-budget blocks', () {
      final controller = LlmToolBudgetController(baseBudget: 20);

      for (var i = 0; i < 30; i++) {
        if (controller.checkBeforeToolCall().requiresAudit) {
          controller.approveAuditExtension();
        }
        controller.recordAcceptedToolCall();
      }

      final auditExtension = controller.approveAuditExtension();
      expect(auditExtension.type, 'audit_extend');
      expect(auditExtension.previousLimit, 30);
      expect(auditExtension.newLimit, 40);
      expect(controller.currentLimit, 40);
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
    });

    test('auditCount increments and tracks triggers properly', () {
      final controller = LlmToolBudgetController(baseBudget: 10);
      expect(controller.auditCount, 0);

      // 缂傚倷鐒﹂〃蹇涘礂濞戞氨鍗氶柟缁㈠枟閳锋捇鏌ら崨濠庡晱闁哥偘绮欓弻銊モ槈濞嗘劗娈ら梺杞伴檷閸婃洟鈥?baseBudget 婵°倗濮烽崑鐐哄磿婵傜鍚规繝濠傜墕缁€澶愭煏婵犲繒鐣遍柍閿嬬墵閺屾稖绠涢幘鏉戞畬闂?15
      for (var i = 0; i < 9; i++) {
        controller.recordAcceptedToolCall();
      }
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
      controller
          .recordAcceptedToolCall(); // 闂佸搫顦弲婊堟偡閵堝洨鍗氶柡澶嬪焾濞?usedCalls = 10闂備焦瀵х粙鎴︽儗娓氣偓瀹曢潧顭ㄩ崼婵堫槷闂侀潧顭粻鎴﹀煕閺嶎厽鐓?limit 闂?15

      // 缂傚倷鐒﹂〃蹇涘礂濞戞俺濮抽柍鍝勬噺閳锋捇鏌ら崨濠庡晱闁哥偘绮欓弻銊モ槈濞嗘劗娈ら梺杞伴檷閸婃洟鈥?15闂備焦瀵х粙鎴︽嚐椤栫偞鍤愰柣鏃傚劋閸犲棝鏌ㄩ弴妤€浜鹃悷婊勬緲閸婅崵鍒?1 婵犵數鍋涘Λ宀勫焵椤掆偓绾绢參寮抽弮鍫熺厱闊洤顑呮俊鍏笺亜閹捐櫕鎲搁柟?
      for (var i = 0; i < 4; i++) {
        controller.recordAcceptedToolCall();
      }
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
      controller.recordAcceptedToolCall(); // usedCalls = 15

      expect(controller.checkBeforeToolCall().requiresAudit, isTrue);
      controller.recordAuditTriggered();
      expect(controller.auditCount, 1);

      controller.approveAuditExtension(); // limit 濠电姭鎷冮崨顓濈捕婵犳鍠氶崑銈呯暦?20
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);

      // 缂傚倷鐒﹂〃蹇涘礂濞戞氨绠斿〒姘ｅ亾婵﹤銈搁幊婊冣枔閸喗鏉搁梻浣瑰缁嬫帒顫濋妸鈺佹瀬闁靛牆鎷嬮悡?20闂備焦瀵х粙鎴︽嚐椤栫偞鍤愰柣鏃傚劋閸犲棝鏌ㄩ弴妤€浜鹃悷婊勬緲閸婅崵鍒?2 婵犵數鍋涘Λ宀勫焵椤掆偓绾绢參寮抽弮鍫熺厱闊洤顑呮俊鍏笺亜閹捐櫕鎲搁柟?
      for (var i = 0; i < 4; i++) {
        controller.recordAcceptedToolCall();
      }
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
      controller.recordAcceptedToolCall(); // usedCalls = 20

      expect(controller.checkBeforeToolCall().requiresAudit, isTrue);
      controller.recordAuditTriggered();
      expect(controller.auditCount, 2);
    });
  });

  group('LlmToolUsageSignals', () {
    test('detects repeated and alternating loop patterns', () {
      const entries = [
        LlmToolLedgerEntry(
          index: 1,
          toolName: 'tool_a',
          signature: 'tool_a:{"id":1}',
          argumentsPreview: '{}',
          outcome: 'success',
          approvalRequired: false,
          approved: false,
          failed: false,
          emptyResult: false,
          resultPreview: '{"ok":true}',
        ),
        LlmToolLedgerEntry(
          index: 2,
          toolName: 'tool_b',
          signature: 'tool_b:{"id":2}',
          argumentsPreview: '{}',
          outcome: 'tool_error',
          approvalRequired: false,
          approved: false,
          failed: true,
          emptyResult: false,
          resultPreview: '{"error":"x"}',
        ),
        LlmToolLedgerEntry(
          index: 3,
          toolName: 'tool_a',
          signature: 'tool_a:{"id":1}',
          argumentsPreview: '{}',
          outcome: 'empty_result',
          approvalRequired: false,
          approved: false,
          failed: true,
          emptyResult: true,
          resultPreview: '{}',
        ),
        LlmToolLedgerEntry(
          index: 4,
          toolName: 'tool_b',
          signature: 'tool_b:{"id":2}',
          argumentsPreview: '{}',
          outcome: 'tool_error',
          approvalRequired: false,
          approved: false,
          failed: true,
          emptyResult: false,
          resultPreview: '{"error":"x"}',
        ),
      ];

      final signals = LlmToolUsageSignals.fromLedger(entries);

      expect(signals.totalCalls, 4);
      expect(signals.failedCalls, 3);
      expect(signals.emptyResults, 1);
      expect(signals.alternatingPairMaxLength, 4);
      expect(signals.suspectedLoop, isTrue);
      expect(signals.likelyNotAdvancing, isTrue);
    });
  });

  group('LlmChatService Plan Mode', () {
    test('systemPromptFor appends plan mode instructions when planMode is true',
        () {
      final storage = StorageService();
      final llmZh = LlmChatService(
        storageService: storage,
        toolService: _MockAiToolExecutor(),
        language: AppLanguage.zh,
      );
      final llmEn = LlmChatService(
        storageService: storage,
        toolService: _MockAiToolExecutor(),
        language: AppLanguage.en,
      );

      final zhNormal = llmZh.systemPromptFor(planMode: false);
      final zhPlan = llmZh.systemPromptFor(planMode: true);
      expect(zhNormal, isNot(contains('[PLAN MODE ACTIVE]')));
      expect(zhPlan, contains('[PLAN MODE ACTIVE]'));
      expect(zhPlan, contains('todoSteps'));
      expect(zhPlan, contains('不会自动创建已保存的可复用 Playbook'));

      final enNormal = llmEn.systemPromptFor(planMode: false);
      final enPlan = llmEn.systemPromptFor(planMode: true);
      expect(enNormal, isNot(contains('[PLAN MODE ACTIVE]')));
      expect(enPlan, contains('[PLAN MODE ACTIVE]'));
      expect(
          enPlan, contains('does not create a saved reusable Playbook record'));
    });

    test('filters state-changing and execution-only tools out of plan mode',
        () async {
      Future<String> noop(Map<String, dynamic> _) async => '{}';

      final executor = _MockAiToolExecutor([
        AiTool(
          name: 'list_servers',
          description: 'read',
          properties: const {},
          handler: noop,
        ),
        AiTool(
          name: 'client_set_clipboard',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'client_set_alarm',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'client_cancel_alarm',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'client_open_app_settings',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'ssh_rename_session',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'update_server_metadata',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'monitor_start',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'create_playbook',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'run_playbook',
          description: 'write',
          properties: const {},
          executionMode: AiToolExecutionMode.stateChanging,
          handler: noop,
        ),
        AiTool(
          name: 'client_task_create',
          description: 'plan',
          properties: const {},
          executionMode: AiToolExecutionMode.planOnly,
          handler: noop,
        ),
        AiTool(
          name: 'client_task_update',
          description: 'exec',
          properties: const {},
          executionMode: AiToolExecutionMode.executionOnly,
          handler: noop,
        ),
        AiTool(
          name: 'client_set_plan_mode',
          description: 'control',
          properties: const {},
          executionMode: AiToolExecutionMode.planControl,
          handler: noop,
        ),
      ]);
      final llm = LlmChatService(
        storageService: StorageService(),
        toolService: executor,
        language: AppLanguage.en,
      );

      final names = llm
          .filterVisibleTools(
            await executor.tools(),
            planMode: true,
          )
          .map((tool) => tool.name)
          .toList();

      expect(
          names,
          containsAll(
              ['list_servers', 'client_task_create', 'client_set_plan_mode']));
      expect(names, isNot(contains('client_set_clipboard')));
      expect(names, isNot(contains('client_set_alarm')));
      expect(names, isNot(contains('client_cancel_alarm')));
      expect(names, isNot(contains('client_open_app_settings')));
      expect(names, isNot(contains('ssh_rename_session')));
      expect(names, isNot(contains('update_server_metadata')));
      expect(names, isNot(contains('monitor_start')));
      expect(names, isNot(contains('create_playbook')));
      expect(names, isNot(contains('run_playbook')));
      expect(names, isNot(contains('client_task_update')));
    });
  });
}

class _MockAiToolExecutor implements AiToolExecutor {
  final List<AiTool> availableTools;

  const _MockAiToolExecutor([this.availableTools = const []]);

  @override
  Future<List<AiTool>> tools() async => availableTools;

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      availableTools.map((tool) => tool.definition).toList(growable: false);

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
          String name, Map<String, dynamic> arguments) async =>
      null;

  @override
  Future<String> execute(String name, Map<String, dynamic> arguments,
          {bool approvedWrite = false}) async =>
      '';

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) =>
      const AiCommandReview.readOnly();
}
