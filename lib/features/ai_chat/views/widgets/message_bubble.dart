import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/agent/plan_execution_controller.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/features/ai_chat/pages/agent_trace_debug_page.dart';
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
  final VoidCallback? onApproveExecute;
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
    this.onApproveExecute,
    this.onRevisePlan,
  });

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<AiChatViewModel>();
    final activeChat = viewModel.activeChat;
    final isLatestAssistant =
        activeChat != null &&
        activeChat.messages.lastIndexWhere((m) => m.role == 'assistant') ==
            index;

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
                              _ChatTodoPanel(
                                chatId: chatId,
                                message: message,
                                onRevisePlan: onRevisePlan,
                              ),
                              if (message.todoSteps.every(
                                    (s) => s.status == StepStatus.pending,
                                  ) &&
                                  isLatestAssistant) ...[
                                const SizedBox(height: 8),
                                _buildApproveButton(context),
                                const SizedBox(height: 4),
                                Center(
                                  child: Text(
                                    strings.language == AppLanguage.en
                                        ? '💡 If you want to modify this plan, simply type your feedback to adjust it.'
                                        : '💡 如果你想修改此计划，直接在下方输入框发送修改意见以进行调整。',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontStyle: FontStyle.italic,
                                      color: colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.8),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                ),
                if (!isUser && message.agentRunId?.trim().isNotEmpty == true)
                  _AgentRunInlineSummary(runId: message.agentRunId!.trim()),
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
                    child: Text(
                      _messageStats(message),
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.72,
                        ),
                        height: 1.2,
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

  Widget _buildApproveButton(BuildContext context) {
    final settings = context.read<AppSettings>();
    final strings = AiStrings(settings.language);
    final theme = Theme.of(context);
    final extColors = theme.extension<ExtendedColors>();

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: FilledButton.icon(
          onPressed: onApproveExecute,
          icon: const Icon(Icons.verified_user_outlined, size: 16),
          label: Text(
            strings.approveAndExecutePlan,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: extColors?.success ?? theme.colorScheme.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
          ),
        ),
      ),
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
    if (message.elapsedMs != null) {
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
