import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
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
      expect(LlmChatService.estimateTextTokens('中文'), 2);
      expect(LlmChatService.estimateTextTokens('abcd中文'), 3);
    });

    test('adds per-message overhead', () {
      final tokens = LlmChatService.estimateMessagesTokens([
        {'role': 'user', 'content': 'abcd'},
        {'role': 'assistant', 'content': '中文'},
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

      // 第一阶段：用满 baseBudget 并自动扩充至 15
      for (var i = 0; i < 9; i++) {
        controller.recordAcceptedToolCall();
      }
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
      controller.recordAcceptedToolCall(); // 这一步 usedCalls = 10，自动扩充 limit 到 15

      // 第二阶段：用满 15，并触发第 1 次安全审计
      for (var i = 0; i < 4; i++) {
        controller.recordAcceptedToolCall();
      }
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);
      controller.recordAcceptedToolCall(); // usedCalls = 15

      expect(controller.checkBeforeToolCall().requiresAudit, isTrue);
      controller.recordAuditTriggered();
      expect(controller.auditCount, 1);

      controller.approveAuditExtension(); // limit 增加到 20
      expect(controller.checkBeforeToolCall().requiresAudit, isFalse);

      // 第三阶段：用满 20，并触发第 2 次安全审计
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
    test('systemPromptFor appends plan mode instructions when planMode is true', () {
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
      expect(zhNormal, isNot(contains('【规划模式已激活】')));
      expect(zhPlan, contains('【规划模式已激活】'));

      final enNormal = llmEn.systemPromptFor(planMode: false);
      final enPlan = llmEn.systemPromptFor(planMode: true);
      expect(enNormal, isNot(contains('[PLAN MODE ACTIVE]')));
      expect(enPlan, contains('[PLAN MODE ACTIVE]'));
    });
  });
}

class _MockAiToolExecutor implements AiToolExecutor {
  @override
  Future<List<AiTool>> tools() async => const [];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async => const [];

  @override
  AiToolApprovalRequest? approvalRequestFor(String name, Map<String, dynamic> arguments) => null;

  @override
  Future<String> execute(String name, Map<String, dynamic> arguments, {bool approvedWrite = false}) async => '';

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) => const AiCommandReview.readOnly();
}
