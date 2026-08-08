part of 'multi_agent_coordinator.dart';

class SubAgentThinkingSettings {
  final bool thinkingEnabled;
  final String reasoningEffort;

  const SubAgentThinkingSettings({
    required this.thinkingEnabled,
    required this.reasoningEffort,
  });
}

typedef MultiAgentClassificationCompletion =
    Future<String> Function(List<Map<String, dynamic>> messages);

typedef MultiAgentCompletion =
    Future<String> Function(
      MultiAgentRole role,
      List<Map<String, dynamic>> messages, {
      required SubAgentThinkingSettings thinkingSettings,
    });

enum MultiAgentTrigger {
  preflight,
  planReview,
  postToolFailure,
  postApprovalRejection,
  postBudgetAudit,
  postLoopGuard,
}

abstract interface class MultiAgentCoordinatorAdapter {
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
  });
}

class MultiAgentDecision {
  final bool enabled;
  final String reason;

  const MultiAgentDecision.enabled(this.reason) : enabled = true;

  const MultiAgentDecision.disabled(this.reason) : enabled = false;
}

class MultiAgentRunResult {
  final int agentCount;
  final String memoryContent;
  final String traceContent;

  const MultiAgentRunResult({
    required this.agentCount,
    required this.memoryContent,
    required this.traceContent,
  });
}

class MultiAgentStructuredSummary {
  final String summary;
  final List<String> recommendedActions;
  final List<String> risks;
  final List<String> openQuestions;

  const MultiAgentStructuredSummary({
    required this.summary,
    this.recommendedActions = const [],
    this.risks = const [],
    this.openQuestions = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'summary': summary,
      'recommendedActions': recommendedActions,
      'risks': risks,
      'openQuestions': openQuestions,
    };
  }
}

class MultiAgentRole {
  final String name;
  final String label;
  final String systemPrompt;

  const MultiAgentRole({
    required this.name,
    required this.label,
    required this.systemPrompt,
  });
}

class AiMultiAgentMaxAgents {
  static const int defaultValue = 3;
  static const List<int> values = [2, 3, 4, 5];

  static int normalize(int? value) {
    if (value == null) return defaultValue;
    return value.clamp(values.first, values.last).toInt();
  }
}

class _RoleOutput {
  final MultiAgentRole role;
  final String content;
  final bool succeeded;

  const _RoleOutput._({
    required this.role,
    required this.content,
    required this.succeeded,
  });

  factory _RoleOutput.success(MultiAgentRole role, String content) {
    return _RoleOutput._(
      role: role,
      content: content.trim().isEmpty ? '(no advice returned)' : content,
      succeeded: true,
    );
  }

  factory _RoleOutput.failure(MultiAgentRole role, String error) {
    return _RoleOutput._(role: role, content: error, succeeded: false);
  }

  String get traceLine =>
      succeeded ? content : 'Helper failed: ${content.trim()}';
}

class _ClassificationDecision {
  final bool shouldCollaborate;
  final String reason;
  final bool thinkingEnabled;
  final String reasoningEffort;
  final int agentCount;

  const _ClassificationDecision({
    required this.shouldCollaborate,
    required this.reason,
    required this.thinkingEnabled,
    required this.reasoningEffort,
    required this.agentCount,
  });

  const _ClassificationDecision.fallback()
    : shouldCollaborate = false,
      reason = 'fallback_due_to_failure',
      thinkingEnabled = false,
      reasoningEffort = 'low',
      agentCount = 2;
}
