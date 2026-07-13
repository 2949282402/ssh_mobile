import 'package:uuid/uuid.dart';

import '../../../services/app_log_service.dart';
import 'llm_chat_service.dart';
import '../../../services/llm_runtime/llm_runtime_types.dart';
import '../../../services/storage_service.dart';
import '../../../services/ai_tool_service.dart';
import 'agent_trace_recorder.dart';
import 'ai_chat_runtime_factory.dart';

sealed class AiChatRunResult {
  String get runId;
  final String finalOutcome;

  bool get succeeded =>
      finalOutcome == 'success' || finalOutcome == 'completed';

  const AiChatRunResult({required this.finalOutcome});
}

class AiChatRunSuccess extends AiChatRunResult {
  @override
  final String runId;
  final String answer;
  final LlmRunStats? runStats;
  const AiChatRunSuccess({
    required this.runId,
    required this.answer,
    required this.runStats,
    required super.finalOutcome,
  });
}

class AiChatRunCancelled extends AiChatRunResult {
  @override
  final String runId;
  final String partialAnswer;
  const AiChatRunCancelled({
    required this.runId,
    required this.partialAnswer,
    required super.finalOutcome,
  });
}

class AiChatRunFailed extends AiChatRunResult {
  @override
  final String runId;
  final Object error;
  final String partialAnswer;
  const AiChatRunFailed({
    required this.runId,
    required this.error,
    required this.partialAnswer,
    required super.finalOutcome,
  });
}

class AiChatGenerationRunner {
  final AiChatRuntimeFactory _runtimeFactory;

  AiChatGenerationRunner({required this._runtimeFactory});

  Future<AiChatRunResult> run({
    required String chatId,
    required AiChatRecord initialChat,
    required String model,
    required String userRequest,
    required List<String> memorySources,
    required Set<String>? allowedTools,
    required bool forceContextCompression,
    required LlmCancellationToken cancellationToken,
    required Set<String> selectedConnectionIds,
    required List<Map<String, dynamic>> requestMessagesJson,
    required void Function(String chunk) onTextChunk,
    required void Function(LlmTraceEvent event) onTrace,
    required Future<AiToolApprovalDecision> Function(AiToolApprovalRequest)
    requestToolApproval,
  }) async {
    final runId = 'run-${const Uuid().v4()}';
    final traceRecorder = AgentTraceRecorder(
      repository: _runtimeFactory.storageService,
      runId: runId,
      chatId: chatId,
    );
    final service = _runtimeFactory.createLlmChatService(
      settings: await _runtimeFactory.storageService.loadAiConnectionSettings(),
      model: model,
      chatId: chatId,
    );

    final answer = StringBuffer();

    try {
      cancellationToken.throwIfCancelled();
      LlmRunStats? runStats;

      await for (final chunk in service.stream(
        modelOverride: model,
        onStats: (stats) => runStats = stats,
        onTrace: (event) {
          traceRecorder.record(event);
          onTrace(event);
        },
        requestToolApproval: requestToolApproval,
        allowedTools: allowedTools,
        forceContextCompression: forceContextCompression,
        cancellationToken: cancellationToken,
        runId: runId,
        planMode: initialChat.planMode,
        userRequest: userRequest,
        selectedConnectionIds: selectedConnectionIds,
        hasWebViewSession: true,
        hasApprovedPlan: initialChat.approvedPlan != null,
        memorySources: memorySources,
        messages: requestMessagesJson,
        approvedPlanMessage: initialChat.approvedPlan == null
            ? null
            : approvedPlanMessageForChat(initialChat),
      )) {
        answer.write(chunk);
        onTextChunk(chunk);
      }

      return AiChatRunSuccess(
        runId: runId,
        answer: answer.toString(),
        runStats: runStats,
        finalOutcome: traceRecorder.finalOutcome ?? 'unknown',
      );
    } on LlmCancelledException {
      return AiChatRunCancelled(
        runId: runId,
        partialAnswer: answer.toString(),
        finalOutcome: traceRecorder.finalOutcome ?? 'cancelled',
      );
    } catch (e) {
      return AiChatRunFailed(
        runId: runId,
        error: e,
        partialAnswer: answer.toString(),
        finalOutcome: traceRecorder.finalOutcome ?? 'modelError',
      );
    } finally {
      try {
        await traceRecorder.flush();
      } catch (e, stackTrace) {
        AppLogService.instance.error(
          'Failed to flush agent trace events',
          error: e,
          stackTrace: stackTrace,
          details: 'chatId=$chatId runId=$runId',
        );
      }
    }
  }
}
