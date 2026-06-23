import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_generation_runner.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_runtime_factory.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/llm_runtime/llm_runtime_types.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'dart:convert';

class ExceptionAiToolExecutor implements AiToolExecutor {
  @override
  Future<List<AiTool>> tools() async {
    throw StateError('Setup failure simulation');
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    return const [];
  }

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return null;
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    return '';
  }

  @override
  AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  }) {
    return const AiCommandReview.readOnly();
  }
}

class FakeTraceRuntimeFactory extends AiChatRuntimeFactory {
  FakeTraceRuntimeFactory({
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
    return LlmChatService(
      storageService: storageService,
      toolService: ExceptionAiToolExecutor(),
      language: appSettings.language,
    );
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

  test('setup phase failure runs finally and flushes start/summary traces',
      () async {
    await storageService.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'dummy-key',
    );

    final factory = FakeTraceRuntimeFactory(
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
        model: 'demo-model',
      ),
      model: 'demo-model',
      userRequest: 'hello',
      memorySources: const [],
      allowedTools: null,
      forceContextCompression: false,
      cancellationToken: LlmCancellationToken(),
      selectedConnectionIds: const {},
      requestMessagesJson: const [],
      onTextChunk: (_) {},
      onTrace: (_) {},
      requestToolApproval: (req) async =>
          const AiToolApprovalDecision.approved(),
    );

    expect(result, isA<AiChatRunFailed>());
    final failed = result as AiChatRunFailed;
    expect(failed.runId, isNotEmpty);

    final traceEvents = await storageService.loadAgentTraceEvents(failed.runId);
    expect(traceEvents, isNotEmpty);

    final started =
        traceEvents.firstWhere((e) => e.kind == 'agent_run_started');
    expect(started, isNotNull);

    final summary =
        traceEvents.firstWhere((e) => e.kind == 'agent_run_summary');
    expect(summary, isNotNull);
    final summaryContent = jsonDecode(summary.content);
    expect(summaryContent['finalOutcome'], 'modelError');
  });
}
