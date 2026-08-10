import 'dart:async';
import '../test_utils/ai_port_adapters.dart';
import '../test_utils/ai_tool_test_adapters.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_tools.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../test_utils/test_storage_adapter.dart';
import 'package:feature_ai/ai_agent.dart';

// --- Mocks for HttpClient for SSE ---
class MockHttpOverrides extends HttpOverrides {
  final List<List<String>> responses;
  int requestCount = 0;

  MockHttpOverrides(this.responses);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final resp = requestCount < responses.length
        ? responses[requestCount]
        : <String>[];
    requestCount++;
    return MockHttpClient(resp);
  }
}

class MockHttpClient implements HttpClient {
  final List<String> responseChunks;

  MockHttpClient(this.responseChunks);

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    return MockHttpClientRequest(responseChunks);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return MockHttpClientRequest(responseChunks);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpClientRequest implements HttpClientRequest {
  final List<String> responseChunks;

  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  int contentLength = 0;

  MockHttpClientRequest(this.responseChunks);

  @override
  void write(Object? obj) {}

  @override
  void add(List<int> data) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async {
    return MockHttpClientResponse(responseChunks);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _headers = {};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final List<String> responseChunks;

  MockHttpClientResponse(this.responseChunks);

  @override
  int get statusCode => 200;

  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  int get contentLength => -1;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => '';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  List<Cookie> get cookies => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final List<List<int>> chunks = [];
    for (final text in responseChunks) {
      final payload = jsonEncode({
        'choices': [
          {
            'delta': {'content': text},
          },
        ],
      });
      chunks.add(utf8.encode('data: $payload\n\n'));
    }
    chunks.add(utf8.encode('data: [DONE]\n\n'));

    return Stream<List<int>>.fromIterable(chunks).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeMultiAgentCoordinator implements MultiAgentCoordinatorAdapter {
  final MultiAgentRunResult? mockResult;

  FakeMultiAgentCoordinator(this.mockResult);

  @override
  Future<MultiAgentRunResult?> run({
    required List<Map<String, dynamic>> messages,
    required bool enabled,
    required int maxAgents,
    required MultiAgentCompletion complete,
    required MultiAgentClassificationCompletion classify,
    void Function()? checkCancelled,
    AppLanguage language = AppLanguage.zh,
    String? plannerPrompt,
    String? operatorPrompt,
    String? explorePrompt,
    String? reviewerPrompt,
    String? summarizerPrompt,
    String? coordinatorPrompt,
    bool planMode = false,
    MultiAgentTrigger trigger = MultiAgentTrigger.preflight,
    String? postToolContext,
  }) async {
    return mockResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late AppSettings appSettings;
  late SshService sshService;
  late SftpService sftpService;
  late ServerDiagnosticsService serverDiagnosticsService;
  late monitoring.MonitoringService performanceMonitorService;
  late AiToolService aiToolService;
  late ChatOrchestrator orchestrator;
  final String testChatId = 'chat-test-123';
  late AiChatRecord activeChat;
  final DateTime now = DateTime.now();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = TestStorageAdapter();
    await storageService.init();
    attachTestAiRepository(storageService);

    appSettings = AppSettings();
    await appSettings.init();

    sshService = createTestSshService(storageService);
    sftpService = createTestSftpService(storageService);
    serverDiagnosticsService = ServerDiagnosticsService(
      connectionRepository: storageService.connectionRepository,
      sshService: sshService,
    );
    performanceMonitorService = createTestPerformanceMonitorService(
      sshService,
      storageService,
    );

    await storageService.saveAiConnectionSettings(
      baseUrl: 'https://api.example.com',
      model: 'demo-model',
      apiKey: 'dummy-key',
    );

    aiToolService = createAiToolServiceFromLegacy(
      storageService: storageService,
      sshService: sshService,
      sftpService: sftpService,
      serverDiagnosticsService: serverDiagnosticsService,
      performanceMonitorToolService: performanceMonitorService,
      appSettings: appSettings,
      clientWebViewSessionId: testChatId,
    );

    orchestrator = ChatOrchestrator(
      storageService: aiStoragePort(storageService),
      contextAssembler: ChatContextAssembler(
        storageService: aiStoragePort(storageService),
      ),
      memoryRetriever: OperationalMemoryRetriever(
        storageService: aiStoragePort(storageService),
        ragService: aiRagCapability(await createTestRagService(storageService)),
      ),
    );

    activeChat = AiChatRecord(
      id: testChatId,
      title: 'Active Chat',
      model: 'demo-model',
      messages: [
        AiChatMessageRecord(
          role: 'user',
          text: 'Pls plan restart',
          createdAt: now.subtract(const Duration(seconds: 1)),
        ),
        AiChatMessageRecord(role: 'assistant', text: '', createdAt: now),
      ],
      createdAt: now.subtract(const Duration(seconds: 2)),
      updatedAt: now,
      planMode: true,
    );
    await storageService.saveAiChat(activeChat);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    HttpOverrides.global = null;
    storageService.dispose();
  });

  group(
    'LlmChatService Plan Mode Output Validation Integration Tests (Single LLM Path)',
    () {
      test(
        'plan mode valid playbook passes without repair, yielding only once',
        () async {
          const validPlaybook = '''
Context: We need to restart nginx.
Proposal:
```playbook
{
  "name": "Nginx restart",
  "description": "restart nginx",
  "steps": [
    {"name": "Check status", "command": "systemctl status nginx", "description": "check"}
  ]
}
```
Verification: check port 80.
''';
          HttpOverrides.global = MockHttpOverrides([
            [validPlaybook],
          ]);

          final llm = LlmChatService(
            storageService: aiStoragePort(storageService),
            toolService: aiToolService,
            language: AppLanguage.en,
            multiAgentCoordinator: FakeMultiAgentCoordinator(null),
          );

          final chunks = <String>[];
          await for (final chunk in llm.stream(
            messages: const [
              {'role': 'user', 'content': 'Pls plan restart'},
            ],
            planMode: true,
          )) {
            chunks.add(chunk);
          }

          // In Plan Mode, chunks are buffered, so we should get exactly 1 unified chunk containing the final validated output.
          expect(chunks, hasLength(1));
          final fullOutput = chunks.first;
          expect(fullOutput, contains('Nginx restart'));
          expect(fullOutput, isNot(contains('Format validation failed')));

          // LlmChatService does not write directly to DB todoSteps anymore
          final chats = await storageService.loadAiChats();
          final chat = chats.firstWhere((c) => c.id == testChatId);
          final assistantMsg = chat.messages.lastWhere(
            (m) => m.role == 'assistant',
          );
          expect(assistantMsg.todoSteps, isEmpty);

          // ChatOrchestrator parses it correctly
          final completion = orchestrator.finalizeAssistantTurn(
            initialChat: activeChat,
            assistantMessage: assistantMsg,
            answerText: fullOutput,
            traces: const [],
          );
          final steps = completion.assistantMessage.todoSteps;
          expect(steps, hasLength(1));
          expect(steps[0].name, 'Check status');
          expect(steps[0].command, 'systemctl status nginx');
        },
      );

      test(
        'plan mode invalid output triggers one repair and returns repaired text only, buffering original',
        () async {
          const invalidPlaybook = '''
Context: We need to restart nginx.
Proposal:
```playbook
{
  "name": "Invalid Playbook JSON",
  "description": "missing steps field"
}
```
''';
          const repairedPlaybook = '''
Proposal:
```playbook
{
  "name": "Repaired Nginx restart",
  "description": "restart nginx",
  "steps": [
    {"name": "Check status", "command": "systemctl status nginx", "description": "check"}
  ]
}
```
''';

          HttpOverrides.global = MockHttpOverrides([
            [invalidPlaybook],
            [repairedPlaybook],
          ]);

          final llm = LlmChatService(
            storageService: aiStoragePort(storageService),
            toolService: aiToolService,
            language: AppLanguage.en,
            multiAgentCoordinator: FakeMultiAgentCoordinator(null),
          );

          final chunks = <String>[];
          await for (final chunk in llm.stream(
            messages: const [
              {'role': 'user', 'content': 'Pls plan restart'},
            ],
            planMode: true,
          )) {
            chunks.add(chunk);
          }

          // Expected chunks:
          // In planMode, the invalid output is buffered and NOT yielded.
          // Then validation fails, so it yields nothing of the first attempt.
          // Then it yields only the repaired text!
          // So the yielded chunks should only contain the repaired playbook.
          final fullOutput = chunks.join();
          expect(fullOutput, isNot(contains('Invalid Playbook JSON')));
          expect(fullOutput, contains('Repaired Nginx restart'));
          expect(
            fullOutput,
            isNot(contains('[Format validation failed. Repairing...]')),
          );

          // Verify ChatOrchestrator parses the repaired text correctly
          final assistantMsg = activeChat.messages.lastWhere(
            (m) => m.role == 'assistant',
          );
          final completion = orchestrator.finalizeAssistantTurn(
            initialChat: activeChat,
            assistantMessage: assistantMsg,
            answerText: fullOutput,
            traces: const [],
          );
          final steps = completion.assistantMessage.todoSteps;
          expect(steps, hasLength(1));
          expect(steps[0].name, 'Check status');
        },
      );

      test(
        'plan mode repair failure returns explicit failure note and original text without looping',
        () async {
          const invalidPlaybook =
              'Plain text plan with no playbook block at all.';
          const repairedPlaybook = 'Still no playbook block here.';

          HttpOverrides.global = MockHttpOverrides([
            [invalidPlaybook],
            [repairedPlaybook],
          ]);

          final llm = LlmChatService(
            storageService: aiStoragePort(storageService),
            toolService: aiToolService,
            language: AppLanguage.en,
            multiAgentCoordinator: FakeMultiAgentCoordinator(null),
          );

          final chunks = <String>[];
          await for (final chunk in llm.stream(
            messages: const [
              {'role': 'user', 'content': 'Pls plan restart'},
            ],
            planMode: true,
          )) {
            chunks.add(chunk);
          }

          final fullOutput = chunks.join();
          // It returns the combined output to let the user see it
          expect(fullOutput, contains('Plan output validation still failed.'));
          expect(fullOutput, contains('Plain text plan'));
          expect(fullOutput, contains('Still no playbook block here'));
        },
      );

      test(
        'non plan mode streams chunks immediately and does not validate',
        () async {
          HttpOverrides.global = MockHttpOverrides([
            ['Hello', ' world!'],
          ]);

          final llm = LlmChatService(
            storageService: aiStoragePort(storageService),
            toolService: aiToolService,
            language: AppLanguage.en,
            multiAgentCoordinator: FakeMultiAgentCoordinator(null),
          );

          final chunks = <String>[];
          await for (final chunk in llm.stream(
            messages: const [
              {'role': 'user', 'content': 'Hi'},
            ],
            planMode: false,
          )) {
            chunks.add(chunk);
          }

          expect(chunks, hasLength(2));
          expect(chunks, ['Hello', ' world!']);
        },
      );
    },
  );

  group(
    'LlmChatService Plan Mode Output Validation Integration Tests (Multi-Agent Path)',
    () {
      test(
        'valid agent playbook JSON skips repair and returns plan content',
        () async {
          const validPlaybook = '''
```playbook
{
  "name": "Agent Nginx restart",
  "description": "restart nginx",
  "steps": [
    {"name": "Check status", "command": "systemctl status nginx", "description": "check"}
  ]
}
```
''';
          final llm = LlmChatService(
            storageService: aiStoragePort(storageService),
            toolService: aiToolService,
            language: AppLanguage.en,
            multiAgentCoordinator: FakeMultiAgentCoordinator(
              const MultiAgentRunResult(
                agentCount: 3,
                memoryContent: validPlaybook,
                traceContent: 'Trace details',
              ),
            ),
          );

          final chunks = <String>[];
          await for (final chunk in llm.stream(
            messages: const [
              {'role': 'user', 'content': 'Pls plan restart'},
            ],
            planMode: true,
          )) {
            chunks.add(chunk);
          }

          final fullOutput = chunks.join();
          expect(fullOutput, contains('Agent Nginx restart'));
          expect(fullOutput, isNot(contains('Format validation failed')));

          final assistantMsg = activeChat.messages.lastWhere(
            (m) => m.role == 'assistant',
          );
          final completion = orchestrator.finalizeAssistantTurn(
            initialChat: activeChat,
            assistantMessage: assistantMsg,
            answerText: fullOutput,
            traces: const [],
          );
          final steps = completion.assistantMessage.todoSteps;
          expect(steps, hasLength(1));
          expect(steps[0].name, 'Check status');
        },
      );

      test(
        'invalid agent playbook triggers repair, succeeds and returns repaired text',
        () async {
          const invalidPlaybook = 'Plaintext output from agents';
          const repairedPlaybook = '''
```playbook
{
  "name": "Repaired Agent Playbook",
  "description": "repaired",
  "steps": [
    {"name": "Check status", "command": "systemctl status nginx", "description": "check"}
  ]
}
```
''';
          HttpOverrides.global = MockHttpOverrides([
            [repairedPlaybook],
          ]);

          final llm = LlmChatService(
            storageService: aiStoragePort(storageService),
            toolService: aiToolService,
            language: AppLanguage.en,
            multiAgentCoordinator: FakeMultiAgentCoordinator(
              const MultiAgentRunResult(
                agentCount: 3,
                memoryContent: invalidPlaybook,
                traceContent: 'Trace details',
              ),
            ),
          );

          final chunks = <String>[];
          await for (final chunk in llm.stream(
            messages: const [
              {'role': 'user', 'content': 'Pls plan restart'},
            ],
            planMode: true,
          )) {
            chunks.add(chunk);
          }

          final fullOutput = chunks.join();
          expect(fullOutput, isNot(contains('Plaintext output')));
          expect(fullOutput, contains('Repaired Agent Playbook'));

          final assistantMsg = activeChat.messages.lastWhere(
            (m) => m.role == 'assistant',
          );
          final completion = orchestrator.finalizeAssistantTurn(
            initialChat: activeChat,
            assistantMessage: assistantMsg,
            answerText: fullOutput,
            traces: const [],
          );
          final steps = completion.assistantMessage.todoSteps;
          expect(steps, hasLength(1));
          expect(steps[0].name, 'Check status');
        },
      );
    },
  );
}
