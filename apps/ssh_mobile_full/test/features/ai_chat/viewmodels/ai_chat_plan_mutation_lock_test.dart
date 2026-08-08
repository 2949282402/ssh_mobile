import 'dart:async';
import '../../../test_utils/ai_port_adapters.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

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

  test('Plan save blocks every stale whole-chat mutation', () async {
    final storage = _GateNextChatSaveStorage();
    final harness = await _MutationHarness.create(storage);
    addTearDown(harness.dispose);
    final viewModel = harness.viewModel();
    addTearDown(viewModel.dispose);
    final chatId = await _seedFailedPlan(viewModel);
    final before = viewModel.activeChat!;
    storage.gateNextChatSave();

    final transition = viewModel.setPlanModeForActiveChat(
      chatId: chatId,
      enabled: true,
    );
    await storage.nextChatSaveStarted;

    await viewModel.retryTodoStep('failed-step');
    await viewModel.skipTodoStep('failed-step', 'skip during save');
    await viewModel.regenerateAssistant(1);
    await viewModel.editUserMessage(0, 'edited during save');
    await viewModel.branchFromAssistant(1);

    expect(viewModel.activeChatId, chatId);
    expect(viewModel.chats, hasLength(1));
    expect(viewModel.activeChat!.messages, before.messages);
    storage.releaseChatSave();
    expect(await transition, SetPlanModeResult.updated);

    final current = viewModel.activeChat!;
    expect(current.planMode, isTrue);
    expect(_step(current).status, StepStatus.failed);
    expect(current.messages.first.text, 'original request');
    final stored = await _storedChat(storage, chatId);
    expect(stored.planMode, isTrue);
    expect(_step(stored).status, StepStatus.failed);
    expect(stored.messages.first.text, 'original request');
  });

  test(
    'TODO save blocks Plan and persists without snapshot overwrite',
    () async {
      final storage = _GateNextChatSaveStorage();
      final harness = await _MutationHarness.create(storage);
      addTearDown(harness.dispose);
      final viewModel = harness.viewModel();
      addTearDown(viewModel.dispose);
      final chatId = await _seedFailedPlan(viewModel);
      storage.gateNextChatSave();

      final skip = viewModel.skipTodoStep('failed-step', 'operator decision');
      await storage.nextChatSaveStarted;
      expect(
        await viewModel.setPlanModeForActiveChat(chatId: chatId, enabled: true),
        SetPlanModeResult.busy,
      );
      storage.releaseChatSave();
      await skip;

      expect(viewModel.activeChat!.planMode, isFalse);
      expect(_step(viewModel.activeChat!).status, StepStatus.skipped);
      final stored = await _storedChat(storage, chatId);
      expect(stored.planMode, isFalse);
      expect(_step(stored).status, StepStatus.skipped);
    },
  );

  for (final action in const ['regenerate', 'edit']) {
    test('$action locks before its first settings await', () async {
      final storage = _GateNextSettingsLoadStorage();
      final harness = await _MutationHarness.create(storage);
      addTearDown(harness.dispose);
      final viewModel = harness.viewModel();
      addTearDown(viewModel.dispose);
      final chatId = await _seedFailedPlan(viewModel);
      storage.gateNextSettingsLoad();

      final mutation = action == 'regenerate'
          ? viewModel.regenerateAssistant(1)
          : viewModel.editUserMessage(0, 'edited request');
      await storage.nextSettingsLoadStarted;
      expect(
        await viewModel.setPlanModeForActiveChat(chatId: chatId, enabled: true),
        SetPlanModeResult.busy,
      );
      await viewModel.branchFromAssistant(1);
      expect(viewModel.chats, hasLength(1));

      storage.releaseSettingsLoad();
      await mutation;
      expect(viewModel.activeChatId, chatId);
      expect(viewModel.activeChat!.planMode, isFalse);
    });
  }

  test(
    'branch holds the write lock until persistence then activates',
    () async {
      final storage = _GateNextChatSaveStorage();
      final harness = await _MutationHarness.create(storage);
      addTearDown(harness.dispose);
      final viewModel = harness.viewModel();
      addTearDown(viewModel.dispose);
      final originalChatId = await _seedFailedPlan(viewModel);
      storage.gateNextChatSave();

      final branch = viewModel.branchFromAssistant(1);
      await storage.nextChatSaveStarted;
      expect(viewModel.activeChatId, originalChatId);
      expect(
        await viewModel.setPlanModeForActiveChat(
          chatId: originalChatId,
          enabled: true,
        ),
        SetPlanModeResult.busy,
      );

      storage.releaseChatSave();
      await branch;
      final branchId = viewModel.activeChatId!;
      expect(branchId, isNot(originalChatId));
      expect(viewModel.chats, hasLength(2));
      final stored = await storage.loadAiChats();
      expect(stored.any((chat) => chat.id == branchId), isTrue);
      expect(
        stored.singleWhere((chat) => chat.id == originalChatId).planMode,
        isFalse,
      );
    },
  );

  test('late history snapshot cannot overwrite a newer Plan state', () async {
    final storage = _GateHistorySnapshotStorage();
    final harness = await _MutationHarness.create(storage);
    addTearDown(harness.dispose);
    final viewModel = harness.viewModel();
    addTearDown(viewModel.dispose);
    final chatId = await _seedFailedPlan(viewModel);
    storage.gateNextHistoryLoad();

    final historyLoad = viewModel.loadHistoryChatsIfNeeded();
    await storage.historySnapshotCaptured;
    expect(
      await viewModel.setPlanModeForActiveChat(chatId: chatId, enabled: true),
      SetPlanModeResult.updated,
    );
    storage.releaseHistoryLoad();
    await historyLoad;

    expect(viewModel.activeChat!.planMode, isTrue);
    expect((await _storedChat(storage, chatId)).planMode, isTrue);
  });

  test('late history snapshot cannot resurrect a deleted chat', () async {
    final storage = _GateHistorySnapshotStorage();
    final harness = await _MutationHarness.create(storage);
    addTearDown(harness.dispose);
    final viewModel = harness.viewModel();
    addTearDown(viewModel.dispose);
    final chatId = await _seedFailedPlan(viewModel);
    storage.gateNextHistoryLoad();

    final historyLoad = viewModel.loadHistoryChatsIfNeeded();
    await storage.historySnapshotCaptured;
    await viewModel.deleteChat(chatId);
    storage.releaseHistoryLoad();
    await historyLoad;

    expect(viewModel.chats.any((chat) => chat.id == chatId), isFalse);
    expect(
      viewModel.savedHistoryChats.any((chat) => chat.id == chatId),
      isFalse,
    );
    expect(
      (await storage.loadAiChats()).any((chat) => chat.id == chatId),
      isFalse,
    );
  });

  test(
    'history load failure clears busy state and remains retryable',
    () async {
      final storage = _FailOnceHistoryLoadStorage();
      final harness = await _MutationHarness.create(storage);
      addTearDown(harness.dispose);
      final viewModel = harness.viewModel();
      addTearDown(viewModel.dispose);
      final chatId = await _seedFailedPlan(viewModel);

      await viewModel.loadHistoryChatsIfNeeded();
      expect(viewModel.historyLoading, isFalse);
      expect(viewModel.savedHistoryChats, isEmpty);

      await viewModel.loadHistoryChatsIfNeeded();
      expect(viewModel.historyLoading, isFalse);
      expect(
        viewModel.savedHistoryChats.any((chat) => chat.id == chatId),
        isTrue,
      );
    },
  );

  test('branch before first history open still loads older chats', () async {
    final storage = StorageService();
    final harness = await _MutationHarness.create(storage);
    addTearDown(harness.dispose);
    final older = AiChatRecord(
      id: 'older-chat',
      title: 'Older chat',
      model: 'test-model',
      createdAt: DateTime.utc(2026, 7, 12),
      updatedAt: DateTime.utc(2026, 7, 12),
      messages: [
        AiChatMessageRecord(
          role: 'user',
          text: 'older request',
          createdAt: DateTime.utc(2026, 7, 12),
        ),
      ],
    );
    await storage.saveAiChat(older);
    final viewModel = harness.viewModel();
    addTearDown(viewModel.dispose);
    final currentChatId = await _seedFailedPlan(viewModel);

    await viewModel.branchFromAssistant(1);
    final branchId = viewModel.activeChatId!;
    await viewModel.loadHistoryChatsIfNeeded();

    final ids = viewModel.chats.map((chat) => chat.id).toSet();
    expect(ids, containsAll(<String>['older-chat', currentChatId, branchId]));
  });
}

Future<String> _seedFailedPlan(AiChatViewModel viewModel) async {
  await viewModel.loadInitialDraft();
  final current = viewModel.activeChat!;
  final createdAt = DateTime.utc(2026, 7, 13, 14);
  final updated = current.copyWith(
    messages: [
      AiChatMessageRecord(
        role: 'user',
        text: 'original request',
        createdAt: createdAt.subtract(const Duration(seconds: 1)),
      ),
      AiChatMessageRecord(
        role: 'assistant',
        text: 'Plan with a failed step',
        createdAt: createdAt,
        todoSteps: const [
          AiTodoStep(
            id: 'failed-step',
            name: 'Inspect service',
            command: 'systemctl status nginx',
            description: 'Read the service status',
            status: StepStatus.failed,
            stderr: 'service unavailable',
            exitCode: 1,
          ),
        ],
      ),
    ],
    updatedAt: createdAt,
  );
  expect(await viewModel.updateActiveChat(updated), isTrue);
  return current.id;
}

AiTodoStep _step(AiChatRecord chat) => chat.messages.last.todoSteps.single;

Future<AiChatRecord> _storedChat(StorageService storage, String id) async {
  return (await storage.loadAiChats()).singleWhere((chat) => chat.id == id);
}

class _MutationHarness {
  final StorageService storage;
  final AppSettings settings;
  final SshService ssh;
  final SftpService sftp;
  final PerformanceMonitorService monitor;
  final PlaybookService playbooks;
  final RagService rag;

  _MutationHarness({
    required this.storage,
    required this.settings,
    required this.ssh,
    required this.sftp,
    required this.monitor,
    required this.playbooks,
    required this.rag,
  });

  static Future<_MutationHarness> create(StorageService storage) async {
    await storage.init();
    attachTestAiRepository(storage);
    final settings = AppSettings();
    await settings.init();
    final ssh = SshService(storage);
    return _MutationHarness(
      storage: storage,
      settings: settings,
      ssh: ssh,
      sftp: SftpService(storage),
      monitor: PerformanceMonitorService(ssh, storage),
      playbooks: PlaybookService(storageService: storage, sshService: ssh),
      rag: RagService(storageService: storage),
    );
  }

  AiChatViewModel viewModel() => createAiChatViewModel(
    storageService: storage,
    sshService: ssh,
    sftpService: sftp,
    performanceMonitorService: monitor,
    playbookService: playbooks,
    ragService: rag,
    appSettings: settings,
  );

  void dispose() {
    settings.dispose();
    storage.dispose();
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

  void releaseChatSave() => _saveGate?.complete();

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

  void releaseSettingsLoad() => _settingsGate?.complete();

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

class _GateHistorySnapshotStorage extends StorageService {
  Completer<void>? _historyGate;
  Completer<void>? _snapshotCaptured;

  Future<void> get historySnapshotCaptured => _snapshotCaptured!.future;

  void gateNextHistoryLoad() {
    _historyGate = Completer<void>();
    _snapshotCaptured = Completer<void>();
  }

  void releaseHistoryLoad() => _historyGate?.complete();

  @override
  Future<List<AiChatRecord>> loadAiChats() async {
    final snapshot = await super.loadAiChats();
    final gate = _historyGate;
    if (gate != null) {
      _snapshotCaptured?.complete();
      await gate.future;
      _historyGate = null;
    }
    return snapshot;
  }
}

class _FailOnceHistoryLoadStorage extends StorageService {
  bool _shouldFail = true;

  @override
  Future<List<AiChatRecord>> loadAiChats() {
    if (_shouldFail) {
      _shouldFail = false;
      throw StateError('simulated history load failure');
    }
    return super.loadAiChats();
  }
}
