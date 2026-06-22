import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_generation_runner.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_runtime_factory.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

class FakeLlmChatService implements LlmChatService {
  final Stream<String> Function(LlmCancellationToken? token) onStream;
  final List<LlmTraceEvent> emittedTraces;
  final AiToolApprovalRequest? approvalRequest;

  String? receivedRunId;
  bool? receivedForceContextCompression;

  FakeLlmChatService({
    required this.onStream,
    this.emittedTraces = const [
      LlmTraceEvent(
        kind: 'reasoning',
        title: 'Thinking',
        content: 'Thinking process',
      ),
    ],
    this.approvalRequest,
  });

  @override
  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)?
        requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    String? runId,
    Set<String>? allowedTools,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool forceContextCompression = false,
    bool planMode = false,
    AiChatMessageRecord? approvedPlanMessage,
  }) {
    receivedRunId = runId;
    receivedForceContextCompression = forceContextCompression;
    // 触发 stats 回调
    if (onStats != null) {
      onStats(LlmRunStats(
        promptTokens: 10,
        completionTokens: 20,
        totalTokens: 30,
        elapsedMs: 100,
        toolCalls: 1,
        cacheHits: 5,
        dedupBlockedCalls: 0,
        approvalCount: 1,
        approvedCount: 1,
        auditEscalationLevel: 0,
        helperFanout: 0,
        selectedToolSet: [],
        memorySources: [],
        usageFromProvider: true,
        contextTokensBeforeCompression: 10,
        contextWindowTokens: 16384,
        compressed: false,
      ));
    }
    if (onTrace != null) {
      for (final event in emittedTraces) {
        onTrace(event);
      }
    }
    if (requestToolApproval != null && approvalRequest != null) {
      requestToolApproval(approvalRequest!);
    }
    return onStream(cancellationToken);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAiChatRuntimeFactory extends AiChatRuntimeFactory {
  final LlmChatService Function() serviceBuilder;

  FakeAiChatRuntimeFactory({
    required this.serviceBuilder,
    required super.storageService,
    required super.sshService,
    required super.sftpService,
    required super.performanceMonitorService,
    required super.playbookService,
    required super.ragService,
    required super.appSettings,
  });

  @override
  LlmChatService createLlmChatService({
    required AiConnectionSettings settings,
    required String model,
    required String chatId,
  }) {
    return serviceBuilder();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SshService sshService;
  late SftpService sftpService;
  late PerformanceMonitorService performanceMonitorService;
  late PlaybookService playbookService;
  late RagService ragService;
  late AppSettings appSettings;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    appSettings = AppSettings();
    await appSettings.init();

    sshService = SshService(storageService);
    sftpService = SftpService(storageService);
    performanceMonitorService =
        PerformanceMonitorService(sshService, storageService);
    playbookService =
        PlaybookService(storageService: storageService, sshService: sshService);
    ragService = RagService(storageService: storageService);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('AiChatGenerationRunner Tests', () {
    test('run executes successfully and yields result', () async {
      final fakeService = FakeLlmChatService(
        onStream: (token) => Stream.fromIterable(['hello', ' world']),
      );

      final factory = FakeAiChatRuntimeFactory(
        serviceBuilder: () => fakeService,
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final runner = AiChatGenerationRunner(runtimeFactory: factory);
      final receivedChunks = <String>[];
      final receivedTraces = <LlmTraceEvent>[];
      final receivedApprovals = <AiToolApprovalRequest>[];

      final result = await runner.run(
        chatId: 'test_chat',
        initialChat: AiChatRecord(
          id: 'test_chat',
          title: 'Title',
          messages: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          model: 'gpt-4o',
        ),
        model: 'gpt-4o',
        userRequest: 'hello',
        memorySources: const [],
        allowedTools: null,
        forceContextCompression: false,
        cancellationToken: LlmCancellationToken(),
        selectedConnectionIds: const {},
        requestMessagesJson: const [],
        onTextChunk: (chunk) => receivedChunks.add(chunk),
        onTrace: (event) => receivedTraces.add(event),
        requestToolApproval: (req) async {
          receivedApprovals.add(req);
          return const AiToolApprovalDecision.approved();
        },
      );

      expect(result, isA<AiChatRunSuccess>());
      final success = result as AiChatRunSuccess;
      expect(success.runId, startsWith('run-'));
      expect(fakeService.receivedRunId, success.runId);
      expect(success.answer, 'hello world');
      expect(success.runStats?.promptTokens, 10);
      expect(success.runStats?.completionTokens, 20);
      expect(receivedChunks, ['hello', ' world']);
      expect(receivedTraces, hasLength(1));
      expect(receivedTraces.first.kind, 'reasoning');
      expect(receivedApprovals, isEmpty);
      final traceEvents =
          await storageService.loadAgentTraceEvents(success.runId);
      expect(traceEvents, hasLength(1));
      expect(traceEvents.single.kind, 'reasoning');
    });

    test('run persists tool, approval, blocked, and compression traces',
        () async {
      final fakeService = FakeLlmChatService(
        emittedTraces: const [
          LlmTraceEvent(
            kind: 'agent_run_started',
            title: 'Agent run started',
            content: '{"runId":"placeholder","model":"gpt-4o"}',
          ),
          LlmTraceEvent(
            kind: 'context_compression_started',
            title: 'Context compression started',
            content: '{"forceContextCompression":true}',
          ),
          LlmTraceEvent(
            kind: 'context_compression_completed',
            title: 'Context compression completed',
            content: '{"compressed":true}',
          ),
          LlmTraceEvent(
            kind: 'tool_request',
            title: 'Tool request: run_command',
            content: '{"tool":"run_command","arguments":{"command":"uptime"}}',
          ),
          LlmTraceEvent(
            kind: 'approval',
            title: 'Tool action rejected',
            content:
                '{"tool":"run_command","status":"rejected","command":"sudo systemctl restart app"}',
          ),
          LlmTraceEvent(
            kind: 'tool_blocked',
            title: 'Tool blocked: hidden_tool (not visible)',
            content:
                '{"tool":"hidden_tool","reason":"not visible in current context"}',
          ),
          LlmTraceEvent(
            kind: 'tool_result',
            title: 'Tool result: hidden_tool',
            content:
                '{"tool":"hidden_tool","outcome":"tool_not_visible","resultPreview":"blocked"}',
          ),
        ],
        onStream: (token) => Stream.fromIterable(['done']),
      );

      final factory = FakeAiChatRuntimeFactory(
        serviceBuilder: () => fakeService,
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final runner = AiChatGenerationRunner(runtimeFactory: factory);
      final result = await runner.run(
        chatId: 'test_chat',
        initialChat: AiChatRecord(
          id: 'test_chat',
          title: 'Title',
          messages: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          model: 'gpt-4o',
        ),
        model: 'gpt-4o',
        userRequest: 'diagnose',
        memorySources: const [],
        allowedTools: null,
        forceContextCompression: true,
        cancellationToken: LlmCancellationToken(),
        selectedConnectionIds: const {},
        requestMessagesJson: const [],
        onTextChunk: (_) {},
        onTrace: (_) {},
        requestToolApproval: (req) async =>
            const AiToolApprovalDecision.rejected(abort: true),
      );

      expect(result, isA<AiChatRunSuccess>());
      final runId = result.runId;
      expect(fakeService.receivedRunId, runId);
      expect(fakeService.receivedForceContextCompression, isTrue);
      final traceEvents = await storageService.loadAgentTraceEvents(runId);
      expect(
        traceEvents.map((event) => event.kind),
        containsAll([
          'agent_run_started',
          'context_compression_started',
          'context_compression_completed',
          'tool_request',
          'approval',
          'tool_blocked',
          'tool_result',
        ]),
      );
      expect(
        traceEvents.firstWhere((event) => event.kind == 'approval').status,
        'rejected',
      );
      expect(
        traceEvents.firstWhere((event) => event.kind == 'tool_result').status,
        'tool_not_visible',
      );
    });

    test('run handles cancellation', () async {
      final controller = StreamController<String>();
      final fakeService = FakeLlmChatService(
        onStream: (token) {
          if (token != null) {
            token.onCancel(() {
              controller.addError(const LlmCancelledException());
              controller.close();
            });
          }
          return controller.stream;
        },
      );

      final factory = FakeAiChatRuntimeFactory(
        serviceBuilder: () => fakeService,
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final runner = AiChatGenerationRunner(runtimeFactory: factory);
      final cancellationToken = LlmCancellationToken();

      // 在添加第一条数据后触发取消
      Timer(const Duration(milliseconds: 50), () {
        controller.add('partial');
        Timer(const Duration(milliseconds: 50), () {
          cancellationToken.cancel();
        });
      });

      final result = await runner.run(
        chatId: 'test_chat',
        initialChat: AiChatRecord(
          id: 'test_chat',
          title: 'Title',
          messages: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          model: 'gpt-4o',
        ),
        model: 'gpt-4o',
        userRequest: 'hello',
        memorySources: const [],
        allowedTools: null,
        forceContextCompression: false,
        cancellationToken: cancellationToken,
        selectedConnectionIds: const {},
        requestMessagesJson: const [],
        onTextChunk: (chunk) {},
        onTrace: (event) {},
        requestToolApproval: (req) async =>
            const AiToolApprovalDecision.approved(),
      );

      expect(result, isA<AiChatRunCancelled>());
      final cancelled = result as AiChatRunCancelled;
      expect(cancelled.runId, startsWith('run-'));
      expect(cancelled.partialAnswer, 'partial');
      expect(await storageService.loadAgentTraceEvents(cancelled.runId),
          isNotEmpty);
    });

    test('run handles errors', () async {
      final fakeService = FakeLlmChatService(
        onStream: (token) => Stream.error(Exception('network error')),
      );

      final factory = FakeAiChatRuntimeFactory(
        serviceBuilder: () => fakeService,
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final runner = AiChatGenerationRunner(runtimeFactory: factory);

      final result = await runner.run(
        chatId: 'test_chat',
        initialChat: AiChatRecord(
          id: 'test_chat',
          title: 'Title',
          messages: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          model: 'gpt-4o',
        ),
        model: 'gpt-4o',
        userRequest: 'hello',
        memorySources: const [],
        allowedTools: null,
        forceContextCompression: false,
        cancellationToken: LlmCancellationToken(),
        selectedConnectionIds: const {},
        requestMessagesJson: const [],
        onTextChunk: (chunk) {},
        onTrace: (event) {},
        requestToolApproval: (req) async =>
            const AiToolApprovalDecision.approved(),
      );

      expect(result, isA<AiChatRunFailed>());
      final failed = result as AiChatRunFailed;
      expect(failed.runId, startsWith('run-'));
      expect(failed.error.toString(), contains('network error'));
      expect(
          await storageService.loadAgentTraceEvents(failed.runId), isNotEmpty);
    });
  });
}
