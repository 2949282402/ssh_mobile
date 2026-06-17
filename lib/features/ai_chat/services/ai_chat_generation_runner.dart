import '../../../services/llm_chat_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/ai_tool_service.dart';
import 'ai_chat_runtime_factory.dart';

sealed class AiChatRunResult {
  const AiChatRunResult();
}

class AiChatRunSuccess extends AiChatRunResult {
  final String answer;
  final LlmRunStats? runStats;
  const AiChatRunSuccess(this.answer, this.runStats);
}

class AiChatRunCancelled extends AiChatRunResult {
  final String partialAnswer;
  const AiChatRunCancelled(this.partialAnswer);
}

class AiChatRunFailed extends AiChatRunResult {
  final Object error;
  final String partialAnswer;
  const AiChatRunFailed(this.error, this.partialAnswer);
}

class AiChatGenerationRunner {
  final AiChatRuntimeFactory _runtimeFactory;

  AiChatGenerationRunner({
    required AiChatRuntimeFactory runtimeFactory,
  }) : _runtimeFactory = runtimeFactory;

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
    final service = _runtimeFactory.createLlmChatService(
      settings: await _runtimeFactory.storageService.loadAiConnectionSettings(),
      model: model,
      chatId: chatId,
    );

    final answer = StringBuffer();

    try {
      LlmRunStats? runStats;

      await for (final chunk in service.stream(
        modelOverride: model,
        onStats: (stats) => runStats = stats,
        onTrace: onTrace,
        requestToolApproval: requestToolApproval,
        allowedTools: allowedTools,
        forceContextCompression: forceContextCompression,
        cancellationToken: cancellationToken,
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

      return AiChatRunSuccess(answer.toString(), runStats);
    } on LlmCancelledException {
      return AiChatRunCancelled(answer.toString());
    } catch (e) {
      return AiChatRunFailed(e, answer.toString());
    }
  }
}
