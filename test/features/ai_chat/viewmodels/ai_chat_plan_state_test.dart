import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_runtime_factory.dart';
import 'package:ssh_mobile/features/ai_chat/services/llm_chat_service.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/client_health_advisor.dart';
import 'package:ssh_mobile/services/llm_runtime/llm_runtime_types.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

import '../../../test_utils/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('Plan state transactions', () {
    test(
      '/plan clears an existing approved plan in memory and storage',
      () async {
        final harness = await _PlanHarness.create();
        addTearDown(harness.dispose);
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        final planCreatedAt = await _seedPlan(
          viewModel,
          planMode: false,
          approvedPlan: _approvedPlanRef(),
        );

        final result = await viewModel.sendText(text: '/plan');

        expect(result, isA<SendTextSlashCommandHandled>());
        expect(viewModel.activeChat!.planMode, isTrue);
        expect(viewModel.activeChat!.approvedPlan, isNull);
        expect(
          _assistantAt(viewModel.activeChat!, planCreatedAt).todoSteps,
          isNotEmpty,
        );
        final stored = await _storedChat(
          harness.storageService,
          viewModel.activeChat!.id,
        );
        expect(stored.planMode, isTrue);
        expect(stored.approvedPlan, isNull);
        expect(runtimeFactory.streamStarts, 0);
      },
    );

    test(
      '/plan args clears an existing approved plan before generation',
      () async {
        final harness = await _PlanHarness.create();
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        await _seedPlan(
          viewModel,
          planMode: false,
          approvedPlan: _approvedPlanRef(),
        );

        final result = await viewModel.sendText(text: '/plan inspect nginx');

        expect(result, isA<SendTextSuccess>());
        expect(viewModel.activeChat!.planMode, isTrue);
        expect(viewModel.activeChat!.approvedPlan, isNull);
        await waitUntil(
          () => !viewModel.sending,
          description: '/plan args generation finishes',
        );
        expect(runtimeFactory.streamStarts, 1);
        final stored = await _storedChat(
          harness.storageService,
          viewModel.activeChat!.id,
        );
        expect(stored.planMode, isTrue);
        expect(stored.approvedPlan, isNull);
      },
    );

    test('/plan locks chat mutations while its state is saving', () async {
      final storageService = _GateNextChatSaveStorage();
      final harness = await _PlanHarness.create(storageService: storageService);
      addTearDown(harness.dispose);
      final runtimeFactory = harness.runtimeFactory();
      final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
      addTearDown(viewModel.dispose);
      final planCreatedAt = await _seedPlan(
        viewModel,
        approvedPlan: _approvedPlanRef(),
      );
      final planChatId = viewModel.activeChat!.id;
      viewModel.createChat('replacement-model');
      final replacementChatId = viewModel.activeChat!.id;
      viewModel.selectChat(planChatId);
      storageService.gateNextChatSave();

      final transition = viewModel.sendText(text: '/plan');
      await storageService.nextChatSaveStarted;

      viewModel.selectChat(replacementChatId);
      viewModel.createChat('third-model');
      await viewModel.deleteChat(planChatId);
      await viewModel.updateActiveChat(
        viewModel.activeChat!.copyWith(
          planMode: false,
          updatedAt: DateTime.now(),
        ),
      );

      expect(viewModel.activeChatId, planChatId);
      expect(viewModel.chats, hasLength(2));
      storageService.releaseChatSave();
      expect(await transition, isA<SendTextSlashCommandHandled>());
      expect(viewModel.activeChat!.planMode, isTrue);
      expect(viewModel.activeChat!.approvedPlan, isNull);
      expect(
        _assistantAt(viewModel.activeChat!, planCreatedAt).todoSteps,
        isNotEmpty,
      );
      expect(runtimeFactory.streamStarts, 0);
    });

    test(
      'delayed health check serializes approval and blocks ordinary sends',
      () async {
        final harness = await _PlanHarness.create();
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final healthAdvisor = _DelayedHealthAdvisor();
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(
          runtimeFactory: runtimeFactory,
          healthAdvisor: healthAdvisor,
        );
        addTearDown(viewModel.dispose);
        final planCreatedAt = await _seedPlan(viewModel);

        final firstApproval = viewModel.approvePlanAndExecute(planCreatedAt);

        await waitUntil(
          () => healthAdvisor.checks == 1,
          description: 'approval reaches delayed health check',
        );
        expect(healthAdvisor.checks, 1);
        expect(viewModel.planApprovalInFlight, isTrue);
        final duplicateApproval = await viewModel.approvePlanAndExecute(
          planCreatedAt,
        );
        final ordinarySend = await viewModel.sendText(text: 'another request');
        expect(duplicateApproval, isA<ApprovePlanExecutionAlreadySending>());
        expect(ordinarySend, isA<SendTextAlreadySending>());
        expect(runtimeFactory.streamStarts, 0);

        healthAdvisor.completeOk();
        expect(await firstApproval, isA<ApprovePlanExecutionStarted>());
        await waitUntil(
          () => !viewModel.sending,
          description: 'approved execution finishes',
        );

        expect(viewModel.planApprovalInFlight, isFalse);
        expect(runtimeFactory.streamStarts, 1);
        expect(
          viewModel.activeChat!.messages.where(
            (message) => message.role == 'user',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'switching chats during health preflight returns PlanChanged without reactivation',
      () async {
        final harness = await _PlanHarness.create();
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final healthAdvisor = _DelayedHealthAdvisor();
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(
          runtimeFactory: runtimeFactory,
          healthAdvisor: healthAdvisor,
        );
        addTearDown(viewModel.dispose);
        final planCreatedAt = await _seedPlan(viewModel);
        final planChatId = viewModel.activeChat!.id;

        final approval = viewModel.approvePlanAndExecute(planCreatedAt);
        viewModel.createChat('replacement-model');
        final replacementChatId = viewModel.activeChat!.id;
        expect(replacementChatId, isNot(planChatId));

        healthAdvisor.completeOk();
        expect(await approval, isA<ApprovePlanExecutionPlanChanged>());

        expect(viewModel.activeChatId, replacementChatId);
        expect(viewModel.activeChat!.messages, isEmpty);
        final original = viewModel.chats.singleWhere(
          (chat) => chat.id == planChatId,
        );
        expect(original.planMode, isFalse);
        expect(original.approvedPlan, isNull);
        expect(runtimeFactory.streamStarts, 0);
      },
    );

    test(
      'missing API key leaves the plan pending and does not execute',
      () async {
        final harness = await _PlanHarness.create();
        addTearDown(harness.dispose);
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        final planCreatedAt = await _seedPlan(viewModel);

        final result = await viewModel.approvePlanAndExecute(planCreatedAt);

        expect(result, isA<ApprovePlanExecutionApiKeyMissing>());
        expect(viewModel.sending, isFalse);
        expect(viewModel.planApprovalInFlight, isFalse);
        expect(viewModel.activeChat!.planMode, isFalse);
        expect(viewModel.activeChat!.approvedPlan, isNull);
        expect(
          _assistantAt(
            viewModel.activeChat!,
            planCreatedAt,
          ).todoSteps.single.status,
          StepStatus.pending,
        );
        expect(
          viewModel.activeChat!.messages.where(
            (message) => message.role == 'user',
          ),
          isEmpty,
        );
        expect(runtimeFactory.streamStarts, 0);
      },
    );

    test('a partial plan still in Plan Mode cannot be approved', () async {
      final harness = await _PlanHarness.create();
      addTearDown(harness.dispose);
      await harness.saveApiKey();
      final runtimeFactory = harness.runtimeFactory();
      final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
      addTearDown(viewModel.dispose);
      final planCreatedAt = await _seedPlan(viewModel, planMode: true);

      final result = await viewModel.approvePlanAndExecute(planCreatedAt);

      expect(result, isA<ApprovePlanExecutionNoPlan>());
      expect(viewModel.activeChat!.planMode, isTrue);
      expect(viewModel.activeChat!.approvedPlan, isNull);
      expect(runtimeFactory.streamStarts, 0);
    });

    test(
      'chat mutations are locked while the approved turn is committing',
      () async {
        final storageService = _GateNextChatSaveStorage();
        final harness = await _PlanHarness.create(
          storageService: storageService,
        );
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        final planCreatedAt = await _seedPlan(viewModel);
        final planChatId = viewModel.activeChat!.id;
        viewModel.createChat('replacement-model');
        final replacementChatId = viewModel.activeChat!.id;
        viewModel.selectChat(planChatId);
        storageService.gateNextChatSave();

        final approval = viewModel.approvePlanAndExecute(planCreatedAt);
        await storageService.nextChatSaveStarted;
        expect(viewModel.sending, isTrue);

        viewModel.selectChat(replacementChatId);
        viewModel.createChat('third-model');
        await viewModel.deleteChat(planChatId);
        await viewModel.updateActiveChat(
          viewModel.activeChat!.copyWith(
            planMode: true,
            updatedAt: DateTime.now(),
          ),
        );

        expect(viewModel.activeChatId, planChatId);
        expect(viewModel.chats, hasLength(2));
        expect(viewModel.activeChat!.planMode, isFalse);

        storageService.releaseChatSave();
        expect(await approval, isA<ApprovePlanExecutionStarted>());
        await waitUntil(
          () => !viewModel.sending,
          description: 'locked approval generation finishes',
        );
        expect(runtimeFactory.streamStarts, 1);
      },
    );

    test(
      'a delete already awaiting settings blocks a later approval commit',
      () async {
        final storageService = _GateNextSettingsLoadStorage();
        final harness = await _PlanHarness.create(
          storageService: storageService,
        );
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        final planCreatedAt = await _seedPlan(viewModel);
        final planChatId = viewModel.activeChat!.id;
        storageService.gateNextSettingsLoad();

        final deletion = viewModel.deleteChat(planChatId);
        await storageService.nextSettingsLoadStarted;
        final approval = await viewModel.approvePlanAndExecute(planCreatedAt);

        expect(approval, isA<ApprovePlanExecutionAlreadySending>());
        expect(runtimeFactory.streamStarts, 0);
        storageService.releaseSettingsLoad();
        await deletion;
        expect(viewModel.activeChatId, isNot(planChatId));
        expect(viewModel.chats.any((chat) => chat.id == planChatId), isFalse);
      },
    );

    test(
      'failed initial chat save returns Failed and keeps approval pending',
      () async {
        final storageService = _FailNextChatSaveStorage();
        final harness = await _PlanHarness.create(
          storageService: storageService,
        );
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        final planCreatedAt = await _seedPlan(viewModel);
        storageService.failNextChatSave = true;

        final result = await viewModel.approvePlanAndExecute(planCreatedAt);

        expect(result, isA<ApprovePlanExecutionFailed>());
        expect(storageService.failedChatSaves, 1);
        expect(viewModel.sending, isFalse);
        expect(viewModel.planApprovalInFlight, isFalse);
        expect(viewModel.activeChat!.planMode, isFalse);
        expect(viewModel.activeChat!.approvedPlan, isNull);
        expect(
          _assistantAt(
            viewModel.activeChat!,
            planCreatedAt,
          ).todoSteps.single.status,
          StepStatus.pending,
        );
        expect(
          viewModel.activeChat!.messages.where(
            (message) => message.role == 'user',
          ),
          isEmpty,
        );
        expect(runtimeFactory.streamStarts, 0);
        final stored = await _storedChat(
          harness.storageService,
          viewModel.activeChat!.id,
        );
        expect(stored.planMode, isFalse);
        expect(stored.approvedPlan, isNull);
        expect(
          _assistantAt(stored, planCreatedAt).todoSteps.single.status,
          StepStatus.pending,
        );
      },
    );

    test(
      'stopping during send preparation prevents generation start',
      () async {
        final storageService = _GateNextSettingsLoadStorage();
        final harness = await _PlanHarness.create(
          storageService: storageService,
        );
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final runtimeFactory = harness.runtimeFactory();
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        await viewModel.loadInitialDraft();
        storageService.gateNextSettingsLoad();

        final send = viewModel.sendText(text: 'cancel before start');
        await storageService.nextSettingsLoadStarted;
        expect(viewModel.sending, isTrue);
        viewModel.stopGeneration();
        expect(viewModel.sending, isFalse);

        storageService.releaseSettingsLoad();
        expect(await send, isA<SendTextStartCancelled>());
        expect(viewModel.activeChat!.messages, isEmpty);
        expect(runtimeFactory.streamStarts, 0);
      },
    );

    test('deleting a streaming chat cannot resurrect it', () async {
      final harness = await _PlanHarness.create();
      addTearDown(harness.dispose);
      await harness.saveApiKey();
      final runtimeFactory = harness.runtimeFactory(
        exit: _StreamExit.waitForCancellation,
      );
      final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
      addTearDown(viewModel.dispose);
      await viewModel.loadInitialDraft();
      final chatId = viewModel.activeChat!.id;

      expect(
        await viewModel.sendText(text: 'keep streaming'),
        isA<SendTextSuccess>(),
      );
      await waitUntil(
        () => runtimeFactory.streamStarts == 1,
        description: 'stream starts before deletion',
      );

      await viewModel.deleteChat(chatId);
      await waitUntil(
        () => !viewModel.sending,
        description: 'deleted generation finishes cancellation',
      );

      expect(viewModel.chats.any((chat) => chat.id == chatId), isFalse);
      expect(
        (await harness.storageService.loadAiChats()).any(
          (chat) => chat.id == chatId,
        ),
        isFalse,
      );
      expect(runtimeFactory.streamStarts, 1);
    });

    for (final exit in const [
      _StreamExit.success,
      _StreamExit.cancelled,
      _StreamExit.failed,
    ]) {
      test(
        'deletion wins when ${exit.name} final chat save is already pending',
        () async {
          final storageService = _GateNumberedChatSaveStorage();
          final harness = await _PlanHarness.create(
            storageService: storageService,
          );
          addTearDown(harness.dispose);
          await harness.saveApiKey();
          final runtimeFactory = harness.runtimeFactory(exit: exit);
          final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
          addTearDown(viewModel.dispose);
          await viewModel.loadInitialDraft();
          final chatId = viewModel.activeChat!.id;
          storageService.gateChatSaveNumber(2);

          expect(
            await viewModel.sendText(text: 'finish into a gated save'),
            isA<SendTextSuccess>(),
          );
          await storageService.gatedChatSaveStarted;
          expect(viewModel.sending, isFalse);

          await viewModel.deleteChat(chatId);
          expect(storageService.completedChatDeletes, 1);
          storageService.releaseChatSave();
          await waitUntil(
            () => storageService.completedChatDeletes == 2,
            description: '${exit.name} final save compensates deletion',
          );

          expect(viewModel.chats.any((chat) => chat.id == chatId), isFalse);
          expect(
            (await storageService.loadAiChats()).any(
              (chat) => chat.id == chatId,
            ),
            isFalse,
          );
        },
      );
    }
  });

  for (final exit in const [
    _StreamExit.success,
    _StreamExit.cancelled,
    _StreamExit.failed,
  ]) {
    test(
      '${exit.name} generation reconciles TODO state saved directly during the stream',
      () async {
        final harness = await _PlanHarness.create();
        addTearDown(harness.dispose);
        await harness.saveApiKey();
        final runtimeFactory = harness.runtimeFactory(
          exit: exit,
          persistTodoDuringStream: true,
        );
        final viewModel = harness.viewModel(runtimeFactory: runtimeFactory);
        addTearDown(viewModel.dispose);
        await viewModel.loadInitialDraft();
        final chatId = viewModel.activeChat!.id;

        final result = await viewModel.sendText(
          text: 'run persisted todo test',
        );

        expect(result, isA<SendTextSuccess>());
        await waitUntil(
          () => !viewModel.sending,
          description: '${exit.name} generation finishes',
        );
        expect(runtimeFactory.streamStarts, 1);

        final memoryAssistant = _assistantWithPersistedTodo(
          viewModel.chats.singleWhere((chat) => chat.id == chatId),
        );
        _expectPersistedTodo(memoryAssistant);
        final stored = await _storedChat(harness.storageService, chatId);
        _expectPersistedTodo(_assistantWithPersistedTodo(stored));

        if (exit == _StreamExit.failed) {
          expect(
            stored.messages.where((message) => message.role == 'error'),
            isNotEmpty,
          );
        } else {
          expect(
            stored.messages.where((message) => message.role == 'error'),
            isEmpty,
          );
        }
      },
    );
  }
}

AiApprovedPlanRef _approvedPlanRef() {
  return AiApprovedPlanRef(
    assistantCreatedAt: DateTime.utc(2026, 7, 13, 8),
    approvedAt: DateTime.utc(2026, 7, 13, 8, 1),
  );
}

Future<DateTime> _seedPlan(
  AiChatViewModel viewModel, {
  bool planMode = false,
  AiApprovedPlanRef? approvedPlan,
}) async {
  await viewModel.loadInitialDraft();
  final createdAt = DateTime.utc(2026, 7, 13, 10);
  final current = viewModel.activeChat!;
  await viewModel.updateActiveChat(
    current.copyWith(
      planMode: planMode,
      approvedPlan: approvedPlan,
      clearApprovedPlan: approvedPlan == null,
      messages: [
        AiChatMessageRecord(
          role: 'assistant',
          text: 'Plan ready',
          createdAt: createdAt,
          todoSteps: const [
            AiTodoStep(
              id: 'plan-step',
              name: 'Inspect service',
              command: 'systemctl status nginx',
              description: 'Read the current service state',
            ),
          ],
        ),
      ],
      updatedAt: createdAt,
    ),
  );
  return createdAt;
}

AiChatMessageRecord _assistantAt(AiChatRecord chat, DateTime createdAt) {
  return chat.messages.singleWhere(
    (message) => message.role == 'assistant' && message.createdAt == createdAt,
  );
}

AiChatMessageRecord _assistantWithPersistedTodo(AiChatRecord chat) {
  return chat.messages.singleWhere(
    (message) =>
        message.role == 'assistant' &&
        message.todoSteps.any((step) => step.id == 'stream-step'),
  );
}

void _expectPersistedTodo(AiChatMessageRecord message) {
  final step = message.todoSteps.singleWhere(
    (item) => item.id == 'stream-step',
  );
  expect(step.status, StepStatus.running);
  expect(step.stdout, 'saved directly by the LLM tool stream');
}

Future<AiChatRecord> _storedChat(
  StorageService storageService,
  String chatId,
) async {
  final chats = await storageService.loadAiChats();
  return chats.singleWhere((chat) => chat.id == chatId);
}

class _PlanHarness {
  final StorageService storageService;
  final AppSettings appSettings;
  final SshService sshService;
  final SftpService sftpService;
  final PerformanceMonitorService performanceMonitorService;
  final PlaybookService playbookService;
  final RagService ragService;

  _PlanHarness({
    required this.storageService,
    required this.appSettings,
    required this.sshService,
    required this.sftpService,
    required this.performanceMonitorService,
    required this.playbookService,
    required this.ragService,
  });

  static Future<_PlanHarness> create({StorageService? storageService}) async {
    final storage = storageService ?? StorageService();
    await storage.init();
    final settings = AppSettings();
    await settings.init();
    final ssh = SshService(storage);
    final sftp = SftpService(storage);
    final monitor = PerformanceMonitorService(ssh, storage);
    return _PlanHarness(
      storageService: storage,
      appSettings: settings,
      sshService: ssh,
      sftpService: sftp,
      performanceMonitorService: monitor,
      playbookService: PlaybookService(
        storageService: storage,
        sshService: ssh,
      ),
      ragService: RagService(storageService: storage),
    );
  }

  Future<void> saveApiKey() {
    return storageService.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'test-model',
      apiKey: 'test-api-key',
    );
  }

  _PlanRuntimeFactory runtimeFactory({
    _StreamExit exit = _StreamExit.success,
    bool persistTodoDuringStream = false,
  }) {
    return _PlanRuntimeFactory(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
      exit: exit,
      persistTodoDuringStream: persistTodoDuringStream,
    );
  }

  AiChatViewModel viewModel({
    required AiChatRuntimeFactory runtimeFactory,
    ClientHealthAdvisorAdapter healthAdvisor = const _ImmediateHealthAdvisor(),
  }) {
    return AiChatViewModel(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      appSettings: appSettings,
      runtimeFactory: runtimeFactory,
      clientHealthAdvisor: healthAdvisor,
    );
  }

  void dispose() {
    appSettings.dispose();
    storageService.dispose();
  }
}

class _ImmediateHealthAdvisor implements ClientHealthAdvisorAdapter {
  const _ImmediateHealthAdvisor();

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) async {
    return _okHealthReport;
  }
}

class _DelayedHealthAdvisor implements ClientHealthAdvisorAdapter {
  final Completer<ClientRuntimeHealthReport> _completer = Completer();
  int checks = 0;

  @override
  Future<ClientRuntimeHealthReport> check({
    ClientHealthCheckProfile profile = ClientHealthCheckProfile.general,
  }) {
    checks += 1;
    return _completer.future;
  }

  void completeOk() {
    _completer.complete(_okHealthReport);
  }
}

const _okHealthReport = ClientRuntimeHealthReport(
  status: ClientRuntimeHealthStatus.ok,
  issues: [],
  raw: {},
);

class _FailNextChatSaveStorage extends StorageService {
  bool failNextChatSave = false;
  int failedChatSaves = 0;

  @override
  Future<void> saveAiChat(AiChatRecord chat) {
    if (failNextChatSave) {
      failNextChatSave = false;
      failedChatSaves += 1;
      throw StateError('simulated chat save failure');
    }
    return super.saveAiChat(chat);
  }
}

class _GateNextChatSaveStorage extends StorageService {
  Completer<void>? _saveGate;
  Completer<void>? _saveStarted;

  Future<void> get nextChatSaveStarted => _saveStarted!.future;

  void gateNextChatSave() {
    _saveGate = Completer<void>();
    _saveStarted = Completer<void>();
  }

  void releaseChatSave() {
    _saveGate?.complete();
  }

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    final gate = _saveGate;
    if (gate != null) {
      _saveStarted?.complete();
      await gate.future;
      _saveGate = null;
    }
    await super.saveAiChat(chat);
  }
}

class _GateNextSettingsLoadStorage extends StorageService {
  Completer<void>? _settingsGate;
  Completer<void>? _settingsStarted;

  Future<void> get nextSettingsLoadStarted => _settingsStarted!.future;

  void gateNextSettingsLoad() {
    _settingsGate = Completer<void>();
    _settingsStarted = Completer<void>();
  }

  void releaseSettingsLoad() {
    _settingsGate?.complete();
  }

  Future<void> _waitForSettingsGate() async {
    final gate = _settingsGate;
    if (gate != null) {
      _settingsStarted?.complete();
      await gate.future;
      _settingsGate = null;
    }
  }

  @override
  Future<AiConnectionSettings> loadAiConnectionSettings() async {
    await _waitForSettingsGate();
    return super.loadAiConnectionSettings();
  }

  @override
  Future<AiRuntimeConnectionSnapshot> loadAiRuntimeConnectionSnapshot() async {
    await _waitForSettingsGate();
    return super.loadAiRuntimeConnectionSnapshot();
  }
}

class _GateNumberedChatSaveStorage extends StorageService {
  int _chatSaveNumber = 0;
  int? _gatedSaveNumber;
  Completer<void>? _saveGate;
  Completer<void>? _saveStarted;
  int completedChatDeletes = 0;

  Future<void> get gatedChatSaveStarted => _saveStarted!.future;

  void gateChatSaveNumber(int saveNumber) {
    _chatSaveNumber = 0;
    _gatedSaveNumber = saveNumber;
    _saveGate = Completer<void>();
    _saveStarted = Completer<void>();
  }

  void releaseChatSave() {
    _saveGate?.complete();
  }

  @override
  Future<void> saveAiChat(AiChatRecord chat) async {
    _chatSaveNumber += 1;
    if (_chatSaveNumber == _gatedSaveNumber) {
      _saveStarted?.complete();
      await _saveGate!.future;
      _gatedSaveNumber = null;
    }
    await super.saveAiChat(chat);
  }

  @override
  Future<void> deleteAiChat(String id) async {
    await super.deleteAiChat(id);
    completedChatDeletes += 1;
  }
}

enum _StreamExit { success, cancelled, failed, waitForCancellation }

class _PlanRuntimeFactory extends AiChatRuntimeFactory {
  final _StreamExit exit;
  final bool persistTodoDuringStream;
  int streamStarts = 0;

  _PlanRuntimeFactory({
    required super.storageService,
    required super.sshService,
    required super.sftpService,
    required super.performanceMonitorService,
    required super.playbookService,
    required super.ragService,
    required super.appSettings,
    required this.exit,
    required this.persistTodoDuringStream,
  });

  @override
  LlmChatService createLlmChatService({
    required AiConnectionSettings settings,
    required String model,
    required String chatId,
    AppLanguage language = AppLanguage.zh,
  }) {
    return _PlanLlmChatService(
      storageService: storageService,
      chatId: chatId,
      exit: exit,
      persistTodoDuringStream: persistTodoDuringStream,
      onStreamStarted: () => streamStarts += 1,
    );
  }
}

class _PlanLlmChatService extends LlmChatService {
  final String chatId;
  final _StreamExit exit;
  final bool persistTodoDuringStream;
  final VoidCallback onStreamStarted;

  _PlanLlmChatService({
    required super.storageService,
    required this.chatId,
    required this.exit,
    required this.persistTodoDuringStream,
    required this.onStreamStarted,
  }) : super(toolService: const _NoopAiToolExecutor());

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
    onStreamStarted();
    if (persistTodoDuringStream) {
      await _persistTodoState();
    }

    switch (exit) {
      case _StreamExit.success:
        onTrace?.call(
          const LlmTraceEvent(
            kind: 'agent_run_summary',
            title: 'Run Summary',
            content: '{"finalOutcome":"success"}',
          ),
        );
        yield 'completed';
        return;
      case _StreamExit.cancelled:
        throw const LlmCancelledException();
      case _StreamExit.failed:
        throw StateError('simulated model failure');
      case _StreamExit.waitForCancellation:
        final cancelled = Completer<void>();
        cancellationToken?.onCancel(cancelled.complete);
        await cancelled.future;
        throw const LlmCancelledException();
    }
  }

  Future<void> _persistTodoState() async {
    final chats = await storageService.loadAiChats();
    final chat = chats.singleWhere((item) => item.id == chatId);
    final messages = [...chat.messages];
    final assistantIndex = messages.lastIndexWhere(
      (message) => message.role == 'assistant',
    );
    if (assistantIndex < 0) {
      throw StateError('assistant placeholder was not persisted');
    }
    messages[assistantIndex] = messages[assistantIndex].copyWith(
      todoSteps: const [
        AiTodoStep(
          id: 'stream-step',
          name: 'Persisted stream task',
          command: 'systemctl restart nginx',
          description: 'Written directly by an LLM tool during streaming',
          status: StepStatus.running,
          stdout: 'saved directly by the LLM tool stream',
        ),
      ],
    );
    await storageService.saveAiChat(
      chat.copyWith(messages: messages, updatedAt: DateTime.now()),
    );
  }
}

class _NoopAiToolExecutor implements AiToolExecutor {
  const _NoopAiToolExecutor();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
