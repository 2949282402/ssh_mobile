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

  FakeLlmChatService({required this.onStream});

  @override
  Stream<String> stream({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    Future<AiToolApprovalDecision> Function(AiToolApprovalRequest request)? requestToolApproval,
    void Function(LlmRunStats stats)? onStats,
    void Function(LlmTraceEvent event)? onTrace,
    LlmCancellationToken? cancellationToken,
    Set<String>? allowedTools,
    String userRequest = '',
    Set<String> selectedConnectionIds = const {},
    bool hasWebViewSession = false,
    bool hasApprovedPlan = false,
    List<String> memorySources = const [],
    bool forceContextCompression = false,
    bool planMode = false,
  }) {
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
      onTrace(const LlmTraceEvent(
        kind: 'reasoning',
        title: 'Thinking',
        content: 'Thinking process',
      ));
    }
    if (requestToolApproval != null) {
      requestToolApproval(
        const AiToolApprovalRequest(
          toolName: 'run_command',
          approvalType: 'execute',
          connectionId: 'conn-123',
          connectionName: 'test-conn',
          command: 'run_cmd',
          reason: 'diagnostics',
        ),
      );
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
      expect(success.answer, 'hello world');
      expect(success.runStats?.promptTokens, 10);
      expect(success.runStats?.completionTokens, 20);
      expect(receivedChunks, ['hello', ' world']);
      expect(receivedTraces, hasLength(1));
      expect(receivedTraces.first.kind, 'reasoning');
      expect(receivedApprovals, hasLength(1));
      expect(receivedApprovals.first.connectionName, 'test-conn');
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
        requestToolApproval: (req) async => const AiToolApprovalDecision.approved(),
      );

      expect(result, isA<AiChatRunCancelled>());
      final cancelled = result as AiChatRunCancelled;
      expect(cancelled.partialAnswer, 'partial');
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
        requestToolApproval: (req) async => const AiToolApprovalDecision.approved(),
      );

      expect(result, isA<AiChatRunFailed>());
      final failed = result as AiChatRunFailed;
      expect(failed.error.toString(), contains('network error'));
    });
  });
}
