part of '../llm_chat_service.dart';

extension LlmChatServiceSafetyAuditor on LlmChatService {
  Future<LlmToolSafetyAuditResult> _runToolSafetyAudit({
    required String baseUrl,
    required String apiKey,
    required String model,
    required bool deepSeekThinkingEnabled,
    required String deepSeekReasoningEffort,
    required String openAiReasoningEffort,
    required String originalUserGoal,
    required List<Map<String, dynamic>> workingMessages,
    required List<LlmToolLedgerEntry> toolLedger,
    required LlmToolBudgetController toolBudget,
    LlmCancellationToken? cancellationToken,
  }) async {
    final signals = LlmToolUsageSignals.fromLedger(toolLedger);
    final recentLedger = toolLedger.length <= 12
        ? toolLedger
        : toolLedger.sublist(toolLedger.length - 12);
    try {
      final response = await _chatCompletion(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        messages: [
          {
            'role': 'system',
            'content':
                'You are a safety auditor for SSH Mobile AI tool usage. Return JSON only with keys shouldContinue, summary, issues, suspectedLoop, goalDrift, recommendedNextAction. Approve only when continued tool use is still clearly advancing the original user goal. Reject when you see repeated identical calls, alternating tool loops, repeated failures, many empty results, or goal drift. Keep summary concise. issues must be a short array of strings.',
          },
          {
            'role': 'user',
            'content': _prettyJson({
              'originalUserGoal': originalUserGoal,
              'recentConversationSummary':
                  _recentConversationSummary(workingMessages),
              'budget': toolBudget.toJson(),
              'deterministicSignals': signals.toJson(),
              'toolLedger': [
                for (final entry in recentLedger) entry.toJson(),
              ],
            }),
          },
        ],
        deepSeekThinkingEnabled: deepSeekThinkingEnabled,
        deepSeekReasoningEffort: deepSeekReasoningEffort,
        openAiReasoningEffort: supportsOpenAiReasoningEffort(model)
            ? 'low'
            : openAiReasoningEffort,
        cancellationToken: cancellationToken,
        operationLabel: 'LLM tool budget safety audit',
      );
      cancellationToken?.throwIfCancelled();
      final content = _contentFromChatResponse(response);
      final auditResult = _parseToolSafetyAuditResult(
        content,
        signals: signals,
      );
      AppLogService.instance.info(
        'LLM tool budget safety audit completed',
        details:
            'shouldContinue=${auditResult.shouldContinue} usedCalls=${toolBudget.usedCalls} currentLimit=${toolBudget.currentLimit}',
      );
      return auditResult;
    } on LlmCancelledException {
      rethrow;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'LLM tool budget safety audit failed',
        error: e,
        stackTrace: stackTrace,
        details:
            'usedCalls=${toolBudget.usedCalls} currentLimit=${toolBudget.currentLimit}',
      );
      return LlmToolSafetyAuditResult.blocked(
        summary:
            'The safety audit could not confirm that continued tool use was still safe.',
        issues: [
          'The internal audit did not complete successfully.',
          'Narrow the next step before asking the assistant to continue.',
        ],
        suspectedLoop: signals.suspectedLoop,
        goalDrift: false,
        recommendedNextAction:
            'Review the recent tool trace, narrow the request, and start a fresh run if you still need more diagnostics.',
      );
    }
  }

  String _recentConversationSummary(List<Map<String, dynamic>> messages) {
    final visibleMessages = messages
        .where((message) => message['role'] != 'system')
        .toList(growable: false);
    final start = visibleMessages.length > 8 ? visibleMessages.length - 8 : 0;
    final window = visibleMessages.sublist(start);
    final buffer = StringBuffer();
    for (final message in window) {
      final role = '${message['role'] ?? 'unknown'}';
      final content = '${message['content'] ?? ''}'.trim();
      if (content.isEmpty) {
        continue;
      }
      buffer.writeln(
        '$role: ${_toolSecretPolicy.previewText(_toolSecretPolicy.redactText(content), maxChars: 500)}',
      );
    }
    final summary = buffer.toString().trim();
    return summary.isEmpty ? 'No recent conversation content.' : summary;
  }

  LlmToolSafetyAuditResult _parseToolSafetyAuditResult(
    String rawContent, {
    required LlmToolUsageSignals signals,
  }) {
    try {
      var text = rawContent.trim();
      if (text.startsWith('```')) {
        text = text
            .replaceFirst(RegExp(r'^```[a-zA-Z0-9_-]*\s*'), '')
            .replaceFirst(RegExp(r'\s*```$'), '')
            .trim();
      }
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start < 0 || end <= start) {
        throw const FormatException('Audit response did not contain JSON.');
      }
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Audit response JSON was not an object.');
      }
      final parsed = LlmToolSafetyAuditResult.fromJson(decoded);
      return LlmToolSafetyAuditResult(
        shouldContinue: parsed.shouldContinue,
        summary: parsed.summary.isNotEmpty
            ? parsed.summary
            : parsed.shouldContinue
                ? 'Continued tool use still appears justified.'
                : 'Continued tool use is no longer justified for this run.',
        issues: parsed.issues,
        suspectedLoop: parsed.suspectedLoop || signals.suspectedLoop,
        goalDrift: parsed.goalDrift,
        recommendedNextAction: parsed.recommendedNextAction.isNotEmpty
            ? parsed.recommendedNextAction
            : 'Review the tool trace and narrow the next requested step.',
      );
    } catch (_) {
      return LlmToolSafetyAuditResult.blocked(
        summary:
            'The safety audit returned an unreadable result, so tool use was stopped.',
        issues: [
          'The internal audit response could not be parsed.',
          'Review the recent tool trace before continuing.',
        ],
        suspectedLoop: signals.suspectedLoop,
        goalDrift: false,
        recommendedNextAction:
            'Start a fresh run with a narrower question or an explicit next command to inspect.',
      );
    }
  }

  String _toolBudgetBlockedToolResult({
    required String toolName,
    required LlmToolBudgetController toolBudget,
    required LlmToolSafetyAuditResult auditResult,
  }) {
    return jsonEncode({
      'error': 'Tool call blocked by tool budget safety audit.',
      'tool': toolName,
      'budget': toolBudget.toJson(),
      'audit': auditResult.toJson(),
    });
  }

  String _toolBudgetRejectedFollowUpPrompt({
    required LlmToolSafetyAuditResult auditResult,
    required LlmToolBudgetController toolBudget,
  }) {
    return '''
Tool use is disabled for the rest of this run because the internal safety audit rejected further tool calls.
Do not request any more tools.
Respond with:
1. A concise summary of useful progress so far.
2. A clear explanation of the tool-use problem.
3. Whether a loop or goal drift was detected.
4. Concrete next steps the user can take.
Budget state: ${jsonEncode(toolBudget.toJson())}
Audit result: ${jsonEncode(auditResult.toJson())}
''';
  }
}
