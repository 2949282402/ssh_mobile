import 'package:feature_ai/src/agent/agent_model_profile.dart';
import 'llm_chat_service.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';

class AiChatRunMetricsRecorder {
  final StorageService _storageService;

  const AiChatRunMetricsRecorder(this._storageService);

  Future<void> record({
    required AgentModelProfile modelProfile,
    required String model,
    required DateTime startedAt,
    required DateTime finishedAt,
    required int ragHits,
    required bool success,
    String? runId,
    LlmRunStats? runStats,
  }) async {
    final promptTokens = runStats?.promptTokens ?? 0;
    final completionTokens = runStats?.completionTokens ?? 0;
    final totalTokens =
        runStats?.totalTokens ?? promptTokens + completionTokens;
    final helperModel = modelProfile.resolve(AgentModelRole.helper);
    final auditModel = modelProfile.resolve(AgentModelRole.audit);

    await _storageService.saveAgentRunMetrics(
      AgentRunMetrics(
        id: runId?.trim().isNotEmpty == true
            ? runId!.trim()
            : 'run-${startedAt.microsecondsSinceEpoch}',
        startedAt: startedAt,
        finishedAt: finishedAt,
        model: model,
        helperModel: helperModel == model ? '' : helperModel,
        auditModel: auditModel == model ? '' : auditModel,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens,
        elapsedMs:
            runStats?.elapsedMs ??
            finishedAt.difference(startedAt).inMilliseconds,
        toolCalls: runStats?.toolCalls ?? 0,
        cacheHits: runStats?.cacheHits ?? 0,
        dedupBlockedCalls: runStats?.dedupBlockedCalls ?? 0,
        ragHits: ragHits,
        approvalCount: runStats?.approvalCount ?? 0,
        approvedCount: runStats?.approvedCount ?? 0,
        auditCount: runStats?.auditEscalationLevel ?? 0,
        helperFanout: runStats?.helperFanout ?? 0,
        success: success,
        selectedToolSet: runStats?.selectedToolSet ?? const [],
        memorySources: runStats?.memorySources ?? const [],
      ),
    );
  }
}
