import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:feature_ai/src/chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'ai_strings.dart';
import 'package:feature_ai/src/agent/plan_execution_controller.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_ai/src/chat/pages/agent_trace_debug_page.dart';
import 'trace_panel.dart';
import 'message_attachments_wrap.dart';

import '../llm_chat_screen.dart'; // For AiStrings/AiStrings extensions

part 'message_run_summary.dart';
part 'message_trace_link.dart';
part 'message_edit_dialog.dart';
part 'message_markdown_body.dart';
part 'message_actions.dart';
part 'message_todo_panel.dart';

class MessageBubble extends StatelessWidget {
  final String chatId;
  final int index;
  final AiChatMessageRecord message;
  final ValueListenable<String>? streamingTextListenable;
  final ValueListenable<String>? streamingStatusListenable;
  final bool canAct;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranch;
  final VoidCallback? onContinueTimeout;
  final VoidCallback? onRevisePlan;

  const MessageBubble({
    super.key,
    required this.chatId,
    required this.index,
    required this.message,
    this.streamingTextListenable,
    this.streamingStatusListenable,
    this.canAct = false,
    this.onEditUser,
    this.onRegenerate,
    this.onBranch,
    this.onContinueTimeout,
    this.onRevisePlan,
  });

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiChatViewModel>();
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AiStrings(language);

    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final isError = message.role == 'error';
    final isAssistant = !isUser && !isError;
    final canCopyAssistant = isAssistant && message.text.trim().isNotEmpty;
    return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (!isUser && !isError && message.traces.isNotEmpty)
                  TracePanel(
                    traces: message.traces,
                    storageKey:
                        'trace-panel-${message.createdAt.microsecondsSinceEpoch}',
                  ),
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isError
                        ? colorScheme.error.withValues(alpha: 0.08)
                        : isUser
                        ? colorScheme.primary.withValues(alpha: 0.14)
                        : colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(AppTheme.radiusMedium),
                      topRight: isUser
                          ? const Radius.circular(4)
                          : const Radius.circular(AppTheme.radiusMedium),
                      bottomLeft: const Radius.circular(AppTheme.radiusMedium),
                      bottomRight: isUser
                          ? const Radius.circular(AppTheme.radiusMedium)
                          : const Radius.circular(4),
                    ),
                    border: Border.all(
                      color: isError
                          ? colorScheme.error.withValues(alpha: 0.3)
                          : isUser
                          ? colorScheme.primary.withValues(alpha: 0.2)
                          : colorScheme.outlineVariant,
                    ),
                  ),
                  child: isUser || isError
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isUser && message.attachments.isNotEmpty)
                              MessageAttachmentsWrap(
                                attachments: message.attachments,
                                isEnglish: language == AppLanguage.en,
                              ),
                            SelectableText(
                              message.text.isEmpty ? '...' : message.text,
                              style: TextStyle(
                                color: isError
                                    ? colorScheme.error
                                    : colorScheme.onSurface,
                                height: 1.35,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _AssistantMarkdownBody(
                              text: message.text,
                              streamingTextListenable: streamingTextListenable,
                              streamingStatusListenable:
                                  streamingStatusListenable,
                            ),
                            if (message.todoSteps.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              ChatTodoPanel(
                                message: message,
                                strings: strings,
                                serverDisplayNameFor: (connectionId) =>
                                    viewModel.getConnection(connectionId)?.name,
                                onRetryStep: viewModel.retryTodoStep,
                                onSkipStep: viewModel.skipTodoStep,
                                onRevisePlan: onRevisePlan,
                              ),
                            ],
                          ],
                        ),
                ),
                if (!isUser && message.agentRunId?.trim().isNotEmpty == true)
                  AgentRunInlineSummary(message: message),
                if (!isUser && message.agentRunId?.trim().isNotEmpty == true)
                  _AgentTraceLink(
                    chatId: chatId,
                    runId: message.agentRunId!.trim(),
                    message: message,
                  ),
                if (canAct &&
                    (onEditUser != null ||
                        onRegenerate != null ||
                        onBranch != null ||
                        onContinueTimeout != null ||
                        canCopyAssistant))
                  MessageActions(
                    isUser: isUser,
                    isError: isError,
                    assistantText: isAssistant ? message.text : null,
                    onEditUser: onEditUser,
                    onRegenerate: onRegenerate,
                    onBranch: onBranch,
                    onContinueTimeout: onContinueTimeout,
                  ),
                if (!isUser && !isError && message.totalTokens != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _messageStats(message),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.72,
                          ),
                          height: 1.2,
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 6),
              ],
            ),
          ),
        )
        .animate(
          key: ValueKey(
            'msg-animate-${message.createdAt.microsecondsSinceEpoch}',
          ),
        )
        .fade(duration: 200.ms)
        .slideX(
          begin: isUser ? 0.05 : -0.05,
          end: 0,
          duration: 200.ms,
          curve: Curves.easeOutQuad,
        );
  }

  String _messageStats(AiChatMessageRecord message) {
    final parts = <String>[];
    if (message.totalTokens != null) {
      parts.add(
        '${message.tokenUsageEstimated == true ? 'est.' : 'API'} tokens ${message.totalTokens}',
      );
    }
    if (message.promptTokens != null || message.completionTokens != null) {
      parts.add(
        'in ${message.promptTokens ?? '-'} / out ${message.completionTokens ?? '-'}',
      );
    }
    if (message.elapsedMs != null &&
        message.agentRunId?.trim().isNotEmpty != true) {
      parts.add('time ${_formatElapsed(message.elapsedMs!)}');
    }
    if (message.promptCacheHitTokens != null ||
        message.promptCacheMissTokens != null) {
      parts.add(
        'cache ${message.promptCacheHitTokens ?? 0}/${message.promptCacheMissTokens ?? 0}',
      );
    }
    if (message.reasoningTokens != null && message.reasoningTokens! > 0) {
      parts.add('reasoning ${message.reasoningTokens}');
    }
    return parts.join(' · ');
  }

  String _formatElapsed(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}
