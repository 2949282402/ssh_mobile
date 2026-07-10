part of 'message_bubble.dart';

class _ChatTodoPanel extends StatefulWidget {
  final String chatId;
  final AiChatMessageRecord message;
  final VoidCallback? onRevisePlan;

  const _ChatTodoPanel({
    required this.chatId,
    required this.message,
    this.onRevisePlan,
  });

  @override
  State<_ChatTodoPanel> createState() => _ChatTodoPanelState();
}

class _ChatTodoPanelState extends State<_ChatTodoPanel> {
  final Set<int> _expandedIndices = {};

  String? _getServerDisplayName(BuildContext context, String? connectionId) {
    if (connectionId == null || connectionId.trim().isEmpty) return null;
    try {
      final viewModel = context.read<AiChatViewModel>();
      final conn = viewModel.getConnection(connectionId);
      return conn?.name ?? 'Server';
    } catch (_) {
      return 'Server';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEn = context.read<AppSettings>().language == AppLanguage.en;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.rule_folder_outlined,
                size: 18,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isEn ? 'Operation Tasks (TODO)' : '规划的运维任务清单 (TODO)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 12),
          for (var i = 0; i < widget.message.todoSteps.length; i++) ...[
            _buildStepRow(
              context,
              i,
              widget.message.todoSteps[i],
              colorScheme,
              isEn,
            ),
            if (i < widget.message.todoSteps.length - 1)
              const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildStepRow(
    BuildContext context,
    int index,
    AiTodoStep step,
    ColorScheme colorScheme,
    bool isEn,
  ) {
    final isExpanded = _expandedIndices.contains(index);
    final hasLogs =
        (step.stdout?.isNotEmpty == true || step.stderr?.isNotEmpty == true);

    final snapshot = const PlanExecutionController().snapshot(
      widget.message.todoSteps,
    );
    final isCurrent = snapshot.currentStep?.id == step.id;
    final isFailed = step.status == StepStatus.failed;
    final isRunning = step.status == StepStatus.running;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedIndices.remove(index);
              } else {
                _expandedIndices.add(index);
              }
            });
          },
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          child: Container(
            decoration: BoxDecoration(
              color: isRunning
                  ? colorScheme.primary.withValues(alpha: 0.08)
                  : isFailed
                  ? colorScheme.error.withValues(alpha: 0.08)
                  : isCurrent && step.status == StepStatus.pending
                  ? colorScheme.secondaryContainer.withValues(alpha: 0.3)
                  : null,
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              border: Border.all(
                color: isRunning
                    ? colorScheme.primary.withValues(alpha: 0.24)
                    : isFailed
                    ? colorScheme.error.withValues(alpha: 0.3)
                    : isCurrent && step.status == StepStatus.pending
                    ? colorScheme.secondary.withValues(alpha: 0.15)
                    : Colors.transparent,
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _buildStatusIcon(step.status, colorScheme),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: step.status == StepStatus.success
                              ? colorScheme.onSurface.withValues(alpha: 0.6)
                              : colorScheme.onSurface,
                          decoration: step.status == StepStatus.success
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      if (step.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            step.description,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (step.connectionId != null &&
                    _getServerDisplayName(context, step.connectionId) !=
                        null) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.6,
                        ),
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 10,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _getServerDisplayName(context, step.connectionId)!,
                            style: TextStyle(
                              fontSize: 9.5,
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 30, top: 4, right: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (step.command.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.48,
                      ),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Text(
                      step.command,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontFamilyFallback: [
                          'Consolas',
                          'Microsoft YaHei',
                          'PingFang SC',
                          'sans-serif',
                        ],
                        fontSize: 10.5,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
                if (isFailed) ...[
                  const SizedBox(height: 6),
                  Text(
                    isEn
                        ? 'Review the logs, retry after fixing the cause, skip only when it is safe, or return to Plan Mode to revise the remaining steps.'
                        : '请先查看日志并修复原因后重试；仅在确认安全时跳过，也可以返回规划模式调整后续步骤。',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          context.read<AiChatViewModel>().retryTodoStep(
                            step.id,
                          );
                        },
                        icon: const Icon(Icons.refresh, size: 13),
                        label: Text(isEn ? 'Retry Step' : '重试此步骤'),
                        style: ElevatedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          textStyle: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final reasonController = TextEditingController();
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogCtx) => AlertDialog(
                              title: Text(isEn ? 'Skip Step' : '跳过步骤'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isEn
                                        ? 'Provide a reason for skipping this task:'
                                        : '请输入跳过此任务的原因：',
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: reasonController,
                                    decoration: InputDecoration(
                                      hintText: isEn
                                          ? 'e.g. Completed manually'
                                          : '例如：已手动完成',
                                      border: const OutlineInputBorder(),
                                    ),
                                    autofocus: true,
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogCtx, false),
                                  child: Text(isEn ? 'Cancel' : '取消'),
                                ),
                                ElevatedButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogCtx, true),
                                  child: Text(isEn ? 'Skip' : '跳过'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true &&
                              reasonController.text.trim().isNotEmpty) {
                            if (context.mounted) {
                              context.read<AiChatViewModel>().skipTodoStep(
                                step.id,
                                reasonController.text.trim(),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.skip_next, size: 13),
                        label: Text(isEn ? 'Skip Step' : '跳过此步骤'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: widget.onRevisePlan,
                        icon: const Icon(Icons.edit_note_outlined, size: 13),
                        label: Text(isEn ? 'Revise Plan' : '调整计划'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
                if (hasLogs) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.84),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '${step.stdout ?? ''}\n${step.stderr ?? ''}'.trim(),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: [
                            'Consolas',
                            'Microsoft YaHei',
                            'PingFang SC',
                            'sans-serif',
                          ],
                          fontSize: 10,
                          color: Colors.greenAccent,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStatusIcon(StepStatus status, ColorScheme colorScheme) {
    switch (status) {
      case StepStatus.pending:
        return Icon(
          Icons.circle_outlined,
          size: 16,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        );
      case StepStatus.running:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case StepStatus.success:
        final extColors = Theme.of(context).extension<ExtendedColors>();
        return Icon(
          Icons.check_circle_rounded,
          size: 16,
          color: extColors?.success ?? colorScheme.primary,
        );
      case StepStatus.failed:
        return Icon(Icons.cancel_rounded, size: 16, color: colorScheme.error);
      case StepStatus.skipped:
        return Icon(
          Icons.next_plan_outlined,
          size: 16,
          color: colorScheme.onSurfaceVariant,
        );
    }
  }
}
