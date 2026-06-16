import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/chat_context_assembler.dart';
import 'package:ssh_mobile/services/chat_orchestrator.dart';
import 'package:ssh_mobile/services/operational_memory_retriever.dart';
import 'package:ssh_mobile/services/rag_service.dart';
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

  test('finalizeAssistantTurn parses playbook steps and exits plan mode',
      () async {
    final storage = StorageService();
    await storage.init();
    final orchestrator = ChatOrchestrator(
      storageService: storage,
      contextAssembler: ChatContextAssembler(storageService: storage),
      memoryRetriever: OperationalMemoryRetriever(
        storageService: storage,
        ragService: RagService(storageService: storage),
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

    storage.dispose();
  });

  test('finalizeAssistantTurn records a plan error when no todo steps persist',
      () async {
    final storage = StorageService();
    await storage.init();
    final orchestrator = ChatOrchestrator(
      storageService: storage,
      contextAssembler: ChatContextAssembler(storageService: storage),
      memoryRetriever: OperationalMemoryRetriever(
        storageService: storage,
        ragService: RagService(storageService: storage),
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

    storage.dispose();
  });
}
