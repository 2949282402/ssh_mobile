part of 'tool_loop_controller_test.dart';

class MockMultiAgentCoordinator implements MultiAgentCoordinatorAdapter {
  MultiAgentTrigger? lastTrigger;
  String? lastPostToolContext;

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
    lastTrigger = trigger;
    lastPostToolContext = postToolContext;
    return const MultiAgentRunResult(
      memoryContent: 'mock memory',
      traceContent: 'mock trace',
      agentCount: 2,
    );
  }
}

class MockToolService implements AiToolExecutor, AiToolApprovalTargetGuard {
  final Future<String> Function(String name, Map<String, dynamic> arguments)
  onExecute;
  final AiToolApprovalRequest? mockApprovalRequest;
  bool approvalTargetCurrent;

  MockToolService({
    required this.onExecute,
    this.mockApprovalRequest,
    this.approvalTargetCurrent = true,
  });

  @override
  Future<List<AiTool>> tools() async => [];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async => [];

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return mockApprovalRequest;
  }

  @override
  Future<bool> isApprovalTargetCurrent(AiToolApprovalRequest request) async {
    return approvalTargetCurrent;
  }

  @override
  Future<String> executeApproved(
    AiToolApprovalRequest request,
    Map<String, dynamic> arguments,
  ) async {
    return onExecute(request.toolName, arguments);
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    return onExecute(name, arguments);
  }

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    return const AiCommandReview.readOnly();
  }
}

class RecordingExecutionToolService implements AiToolExecutor {
  RecordingExecutionToolService(this.delegate);

  final AiToolExecutor delegate;
  bool executed = false;

  @override
  Future<List<AiTool>> tools() => delegate.tools();

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() =>
      delegate.toolDefinitions();

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) => delegate.approvalRequestFor(name, arguments);

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    executed = true;
    return '{"ok":true}';
  }

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) =>
      delegate.reviewCommand(command, platform: platform);
}
