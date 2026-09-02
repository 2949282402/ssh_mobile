import 'package:flutter/foundation.dart';
import '../test_utils/ai_port_adapters.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';

import '../test_utils/test_storage_adapter.dart';
import 'package:ssh_mobile/services/app_settings.dart';

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

  test(
    'finalizeAssistantTurn parses playbook steps and exits plan mode',
    () async {
      final storage = TestStorageAdapter();
      await storage.init();
      attachTestAiRepository(storage);
      final orchestrator = ChatOrchestrator(
        storageService: aiStoragePort(storage),
        contextAssembler: ChatContextAssembler(
          storageService: aiStoragePort(storage),
        ),
        memoryRetriever: OperationalMemoryRetriever(
          storageService: aiStoragePort(storage),
          ragService: aiRagCapability(await createTestRagService(storage)),
        ),
      );
      final now = DateTime.now();
      final chat = AiChatRecord(
        id: 'chat-1',
        title: 'Draft',
        model: 'demo-model',
        messages: const [],
        createdAt: now,
        updatedAt: now,
        planMode: true,
      );
      final assistant = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
      );

      final completion = orchestrator.finalizeAssistantTurn(
        initialChat: chat,
        assistantMessage: assistant,
        answerText: '''
```playbook
{"steps":[{"name":"Check service","command":"systemctl status nginx","description":"Inspect nginx"}]}
```
''',
        traces: const [],
      );

      expect(completion.shouldExitPlanMode, isTrue);
      expect(completion.assistantMessage.todoSteps, hasLength(1));
      expect(completion.assistantMessage.todoSteps.first.name, 'Check service');
      expect(
        completion.assistantMessage.todoSteps.first.status.name,
        'pending',
      );

      await storage.shutdown();
      storage.dispose();
    },
  );

  test(
    'finalizeAssistantTurn records a plan error when no todo steps persist',
    () async {
      final storage = TestStorageAdapter();
      await storage.init();
      attachTestAiRepository(storage);
      final orchestrator = ChatOrchestrator(
        storageService: aiStoragePort(storage),
        contextAssembler: ChatContextAssembler(
          storageService: aiStoragePort(storage),
        ),
        memoryRetriever: OperationalMemoryRetriever(
          storageService: aiStoragePort(storage),
          ragService: aiRagCapability(await createTestRagService(storage)),
        ),
      );
      final now = DateTime.now();
      final chat = AiChatRecord(
        id: 'chat-2',
        title: 'Draft',
        model: 'demo-model',
        messages: const [],
        createdAt: now,
        updatedAt: now,
        planMode: true,
      );
      final assistant = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
      );

      final completion = orchestrator.finalizeAssistantTurn(
        initialChat: chat,
        assistantMessage: assistant,
        answerText: 'No playbook emitted.',
        traces: const [],
      );

      expect(completion.shouldExitPlanMode, isFalse);
      expect(completion.assistantMessage.todoSteps, isEmpty);
      expect(
        completion.assistantMessage.traces.any(
          (trace) => trace.kind == 'plan_error',
        ),
        isTrue,
      );

      await storage.shutdown();
      storage.dispose();
    },
  );

  test(
    'prepareTurn retrieves relevant skills, clips references and formats contextText',
    () async {
      final storage = TestStorageAdapter();
      await storage.init();
      attachTestAiRepository(storage);

      // 注入启用和禁用的 Skill
      final activeSkill = AiSkillRecord(
        id: 'active-skill',
        name: 'Docker Help',
        description: 'Useful docker tips',
        content: 'Docker main instructions.',
        enabled: true,
        references: const [
          SkillReferenceItem(
            title: 'Docker Cleanup',
            content: 'Run docker system prune to free up space.',
          ),
          SkillReferenceItem(
            title: 'Docker Build',
            content: 'Use docker build -t image . to build container.',
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final disabledSkill = AiSkillRecord(
        id: 'disabled-skill',
        name: 'Nginx Help',
        description: 'Nginx config guide',
        content: 'Nginx main body.',
        enabled: false,
        references: const [
          SkillReferenceItem(
            title: 'Nginx Restart',
            content: 'systemctl restart nginx',
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await storage.saveAiSkill(activeSkill);
      await storage.saveAiSkill(disabledSkill);

      final orchestrator = ChatOrchestrator(
        storageService: aiStoragePort(storage),
        contextAssembler: ChatContextAssembler(
          storageService: aiStoragePort(storage),
        ),
        memoryRetriever: OperationalMemoryRetriever(
          storageService: aiStoragePort(storage),
        ),
      );

      final now = DateTime.now();
      final chat = AiChatRecord(
        id: 'chat-prepare-test',
        title: 'Active Chat',
        model: 'demo-model',
        messages: const [],
        createdAt: now,
        updatedAt: now,
        planMode: false,
      );

      // 1. 发起匹配启用 Skill reference 的查询
      final prepMatched = await orchestrator.prepareTurn(
        chat: chat,
        text: 'prune cleanup',
        createdAt: now,
        language: AppLanguage.en,
        attachments: const [],
      );

      expect(prepMatched.userMessage.contextText, isNotNull);
      // 应当包含 【运维经验记忆】 或 [Operational memory references]
      expect(
        prepMatched.userMessage.contextText,
        contains('[Operational memory references]'),
      );
      expect(
        prepMatched.userMessage.contextText,
        contains('<UNTRUSTED_OPERATIONAL_MEMORY>'),
      );
      expect(
        prepMatched.userMessage.contextText,
        contains('</UNTRUSTED_OPERATIONAL_MEMORY>'),
      );
      // 应当包含命中的 reference 标题和具体内容
      expect(prepMatched.userMessage.contextText, contains('Docker Cleanup'));
      expect(
        prepMatched.userMessage.contextText,
        contains('docker system prune'),
      );
      // 应当不包含未命中的 reference（因为 clips matches 逻辑只带回匹配的 references）
      expect(
        prepMatched.userMessage.contextText,
        isNot(contains('Docker Build')),
      );
      expect(
        prepMatched.userMessage.contextText,
        isNot(contains('docker build -t')),
      );

      // 验证 traces 里也包含了 memory_context 记录
      expect(prepMatched.assistantMessage.traces, hasLength(1));
      expect(
        prepMatched.assistantMessage.traces.first.kind,
        equals('memory_context'),
      );
      expect(
        prepMatched.assistantMessage.traces.first.content,
        contains('Docker Cleanup'),
      );

      // 2. 发起匹配已禁用 Skill 的查询
      final prepDisabled = await orchestrator.prepareTurn(
        chat: chat,
        text: 'restart nginx services',
        createdAt: now,
        language: AppLanguage.en,
        attachments: const [],
      );

      // 禁用的 Skill 应该完全不参与召回
      expect(
        prepDisabled.userMessage.contextText,
        isNot(contains('Nginx Restart')),
      );
      expect(
        prepDisabled.userMessage.contextText,
        isNot(contains('systemctl restart nginx')),
      );
      expect(prepDisabled.assistantMessage.traces, isEmpty);

      await storage.shutdown();
      storage.dispose();
    },
  );

  test(
    'finalizeAssistantTurn preserves existing todoSteps and does not overwrite',
    () async {
      final storage = TestStorageAdapter();
      await storage.init();
      attachTestAiRepository(storage);
      final orchestrator = ChatOrchestrator(
        storageService: aiStoragePort(storage),
        contextAssembler: ChatContextAssembler(
          storageService: aiStoragePort(storage),
        ),
        memoryRetriever: OperationalMemoryRetriever(
          storageService: aiStoragePort(storage),
          ragService: aiRagCapability(await createTestRagService(storage)),
        ),
      );
      final now = DateTime.now();
      final chat = AiChatRecord(
        id: 'chat-preserve',
        title: 'Draft',
        model: 'demo-model',
        messages: const [],
        createdAt: now,
        updatedAt: now,
        planMode: true,
      );
      final assistant = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
        todoSteps: const [
          AiTodoStep(
            id: 'existing-1',
            name: 'Existing Step',
            command: 'echo existing',
            description: '',
          ),
        ],
      );

      final completion = orchestrator.finalizeAssistantTurn(
        initialChat: chat,
        assistantMessage: assistant,
        answerText: '''
```playbook
{"steps":[{"name":"New Step","command":"echo new"}]}
```
''',
        traces: const [],
      );

      expect(completion.assistantMessage.todoSteps, hasLength(1));
      expect(completion.assistantMessage.todoSteps.first.id, 'existing-1');
      expect(completion.assistantMessage.todoSteps.first.name, 'Existing Step');

      await storage.shutdown();
      storage.dispose();
    },
  );

  test(
    'finalizeAssistantTurn skips first invalid playbook and parses second valid playbook',
    () async {
      final storage = TestStorageAdapter();
      await storage.init();
      attachTestAiRepository(storage);
      final orchestrator = ChatOrchestrator(
        storageService: aiStoragePort(storage),
        contextAssembler: ChatContextAssembler(
          storageService: aiStoragePort(storage),
        ),
        memoryRetriever: OperationalMemoryRetriever(
          storageService: aiStoragePort(storage),
          ragService: aiRagCapability(await createTestRagService(storage)),
        ),
      );
      final now = DateTime.now();
      final chat = AiChatRecord(
        id: 'chat-two-playbooks',
        title: 'Draft',
        model: 'demo-model',
        messages: const [],
        createdAt: now,
        updatedAt: now,
        planMode: true,
      );
      final assistant = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
      );

      final completion = orchestrator.finalizeAssistantTurn(
        initialChat: chat,
        assistantMessage: assistant,
        answerText: '''
First bad block:
```playbook
{"steps":[]}
```

Second good block:
```playbook
{"steps":[{"name":"Good step","command":"echo 1"}]}
```
''',
        traces: const [],
      );

      expect(completion.shouldExitPlanMode, isTrue);
      expect(completion.assistantMessage.todoSteps, hasLength(1));
      expect(completion.assistantMessage.todoSteps.first.name, 'Good step');

      await storage.shutdown();
      storage.dispose();
    },
  );

  test(
    'finalizeAssistantTurn fails parsing steps with missing name and skips block',
    () async {
      final storage = TestStorageAdapter();
      await storage.init();
      attachTestAiRepository(storage);
      final orchestrator = ChatOrchestrator(
        storageService: aiStoragePort(storage),
        contextAssembler: ChatContextAssembler(
          storageService: aiStoragePort(storage),
        ),
        memoryRetriever: OperationalMemoryRetriever(
          storageService: aiStoragePort(storage),
          ragService: aiRagCapability(await createTestRagService(storage)),
        ),
      );
      final now = DateTime.now();
      final chat = AiChatRecord(
        id: 'chat-missing-name',
        title: 'Draft',
        model: 'demo-model',
        messages: const [],
        createdAt: now,
        updatedAt: now,
        planMode: true,
      );
      final assistant = AiChatMessageRecord(
        role: 'assistant',
        text: '',
        createdAt: now,
      );

      final completion = orchestrator.finalizeAssistantTurn(
        initialChat: chat,
        assistantMessage: assistant,
        answerText: '''
```playbook
{"steps":[{"command":"echo 1"}]}
```
''',
        traces: const [],
      );

      expect(completion.shouldExitPlanMode, isFalse);
      expect(completion.assistantMessage.todoSteps, isEmpty);

      await storage.shutdown();
      storage.dispose();
    },
  );
}
