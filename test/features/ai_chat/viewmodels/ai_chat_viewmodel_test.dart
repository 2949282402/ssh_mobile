import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_runtime_factory.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import '../../../test_utils/wait_until.dart';

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

  group('AiChatViewModel Tests', () {
    test('loadInitialDraft loads a draft and updates state', () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      expect(viewModel.loading, isTrue);
      expect(viewModel.chats, isEmpty);
      expect(viewModel.activeChatId, isNull);

      await viewModel.loadInitialDraft();

      expect(viewModel.loading, isFalse);
      expect(viewModel.chats, hasLength(1));
      expect(viewModel.activeChatId, isNotNull);
      expect(viewModel.activeChat!.messages, isEmpty);
    });

    test('sendText returns SendTextEmptyText for empty text', () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();

      final result = await viewModel.sendText(text: '');
      expect(result, isA<SendTextEmptyText>());
    });

    test('sendText returns SendTextApiKeyMissing if api key is missing',
        () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();

      final result = await viewModel.sendText(text: 'hello');
      expect(result, isA<SendTextApiKeyMissing>());
    });

    test('addAttachment and removeAttachment works correctly', () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();

      expect(viewModel.pendingAttachments, isEmpty);

      final attachment = const AiChatAttachment(
        fileName: 'test.png',
        mimeType: 'image/png',
        sizeBytes: 100,
        dataBase64: 'abc',
      );

      viewModel.addAttachment(attachment);
      expect(viewModel.pendingAttachments, hasLength(1));
      expect(viewModel.pendingAttachments.first.fileName, 'test.png');

      viewModel.removeAttachmentAt(0);
      expect(viewModel.pendingAttachments, isEmpty);
    });

    test('deleteChat fallback to new draft if list is empty', () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();
      final originalId = viewModel.activeChatId!;

      await Future.delayed(const Duration(milliseconds: 1));

      await viewModel.deleteChat(originalId);

      expect(viewModel.chats, hasLength(1));
      expect(viewModel.activeChatId, isNot(originalId));
    });

    test('updateAllowedTools updates tools correctly', () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();
      final activeChatId = viewModel.activeChatId!;

      viewModel.updateAllowedTools(activeChatId, {'tool1', 'tool2'});
      // Internally stored, let's verify that we can execute sendText slash command for /tools and check result
      final result = await viewModel.sendText(text: '/tools');
      expect(result, isA<SendTextSlashCommandOpenToolsSelector>());
      final openSelector = result as SendTextSlashCommandOpenToolsSelector;
      expect(openSelector.currentAllowedTools, containsAll(['tool1', 'tool2']));
    });

    test('getConnection and connections returns expected values', () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      expect(viewModel.connections, isEmpty);
      expect(viewModel.getConnection('non_existent'), isNull);
    });

    test('checkPendingDiagnosticPrompt retrieves and clears pending prompt',
        () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      playbookService.pendingDiagnosticPrompt = 'diagnose_me';
      expect(viewModel.checkPendingDiagnosticPrompt(), 'diagnose_me');
      expect(playbookService.pendingDiagnosticPrompt, isNull);
      expect(viewModel.checkPendingDiagnosticPrompt(), isNull);
    });

    test('loadLlmSettingsData and logLlmSettingsOpened works without errors',
        () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final data = await viewModel.loadLlmSettingsData();
      expect(data, isNotNull);
      expect(data['settings'], isNotNull);

      // Verify that calling logLlmSettingsOpened runs without throwing
      final settings = data['settings'] as AiConnectionSettings;
      expect(() => viewModel.logLlmSettingsOpened(settings), returnsNormally);
    });

    test(
        '/plan alone enables Plan Mode and returns slash-command handled feedback',
        () async {
      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      await viewModel.loadInitialDraft();
      expect(viewModel.activeChat!.planMode, isFalse);

      final result = await viewModel.sendText(text: '/plan');
      expect(result, isA<SendTextSlashCommandHandled>());
      expect(viewModel.activeChat!.planMode, isTrue);
    });

    test(
        '/plan <args> enables Plan Mode and proceeds into the normal send flow',
        () async {
      final factory = FakeSuccessRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        runtimeFactory: factory,
      );

      await viewModel.loadInitialDraft();
      expect(viewModel.activeChat!.planMode, isFalse);

      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );

      final result = await viewModel.sendText(text: '/plan diagnose nginx');
      expect(result, isA<SendTextSuccess>());
      expect(viewModel.activeChat!.planMode, isTrue);

      // Wait for generation to finish to avoid unawaited async leaks
      await waitUntil(
        () => viewModel.sending == false,
        description: 'generation finishes',
      );

      final messages = viewModel.activeChat!.messages;
      final userMessage = messages.firstWhere((m) => m.role == 'user');
      expect(userMessage.text, equals('diagnose nginx'));
    });

    test(
        'generate assistant response failure with empty partialAnswer assigns agentRunId to error message',
        () async {
      await storageService.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );

      final factory = FakeFailureRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );

      final viewModel = AiChatViewModel(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
        runtimeFactory: factory,
      );

      await viewModel.loadInitialDraft();
      final result = await viewModel.sendText(text: 'hello');
      expect(result, isA<SendTextSuccess>());

      // Wait for async runner execution
      await waitUntil(
        () => viewModel.activeChat?.messages.any((m) => m.role == 'error') == true,
        description: 'error message after failed generation',
      );
      await waitUntil(
        () => viewModel.sending == false,
        description: 'generation finishes after failure',
      );

      final messages = viewModel.activeChat!.messages;
      expect(messages, isNotEmpty);
      final errorMessage = messages.firstWhere((m) => m.role == 'error');
      expect(errorMessage.agentRunId, isNotNull);
      expect(errorMessage.agentRunId, isNotEmpty);
    });
  });
}

class FailureLlmChatService extends LlmChatService {
  FailureLlmChatService({
    required super.storageService,
  }) : super(
          toolService: const _FakeAiToolExecutor(),
        );

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
    throw StateError('Chat service failure');
  }
}

class FakeSuccessLlmChatService extends LlmChatService {
  FakeSuccessLlmChatService({
    required super.storageService,
  }) : super(
          toolService: const _FakeAiToolExecutor(),
        );

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
  }) async* {
    if (onTrace != null) {
      onTrace(const LlmTraceEvent(
        kind: 'agent_run_summary',
        title: 'Run Summary',
        content: '{"finalOutcome":"success","stepsCount":0,"durationMs":0}',
      ));
    }
    if (onStats != null) {
      onStats(const LlmRunStats(
        promptTokens: 10,
        completionTokens: 20,
        totalTokens: 30,
        elapsedMs: 100,
        usageFromProvider: true,
        contextTokensBeforeCompression: 10,
        contextWindowTokens: 259000,
        compressed: false,
      ));
    }
    yield 'ok';
  }
}

class _FakeAiToolExecutor implements AiToolExecutor {
  const _FakeAiToolExecutor();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeFailureRuntimeFactory extends AiChatRuntimeFactory {
  FakeFailureRuntimeFactory({
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
    return FailureLlmChatService(storageService: storageService);
  }
}

class FakeSuccessRuntimeFactory extends AiChatRuntimeFactory {
  FakeSuccessRuntimeFactory({
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
    return FakeSuccessLlmChatService(storageService: storageService);
  }
}
