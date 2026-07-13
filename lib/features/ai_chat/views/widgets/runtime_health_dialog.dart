part of '../llm_chat_screen.dart';

Future<bool> showRuntimeHealthPreflightDialog({
  required BuildContext context,
  required ClientRuntimeHealthReport report,
  required bool allowContinue,
  required AiStrings strings,
  required Future<void> Function() onOpenSystemSettings,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  final result = await showDialog<bool>(
    context: context,
    useSafeArea: true,
    builder: (_) => RuntimeHealthDialogContent(
      report: report,
      allowContinue: allowContinue,
      strings: strings,
      onOpenSystemSettings: onOpenSystemSettings,
    ),
  );
  return result == true;
}

class RuntimeHealthDialogContent extends StatefulWidget {
  final ClientRuntimeHealthReport report;
  final bool allowContinue;
  final AiStrings strings;
  final Future<void> Function() onOpenSystemSettings;

  const RuntimeHealthDialogContent({
    super.key,
    required this.report,
    required this.allowContinue,
    required this.strings,
    required this.onOpenSystemSettings,
  });

  @override
  State<RuntimeHealthDialogContent> createState() =>
      _RuntimeHealthDialogContentState();
}

class _RuntimeHealthDialogContentState
    extends State<RuntimeHealthDialogContent> {
  bool _openingSettings = false;
  bool _closing = false;

  void _finish(bool result) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  Future<void> _openSystemSettings() async {
    if (_openingSettings || _closing) return;
    setState(() => _openingSettings = true);
    try {
      await widget.onOpenSystemSettings();
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        'Failed to open system settings from runtime health dialog',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (mounted) _finish(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final visibleHeight = (media.size.height - media.viewInsets.bottom)
        .clamp(0.0, media.size.height)
        .toDouble();
    final compact = visibleHeight < 360;
    final maxDialogHeight = (visibleHeight - (compact ? 16 : 32))
        .clamp(160.0, 640.0)
        .toDouble();
    final title = widget.allowContinue
        ? widget.strings.runtimeWarningsTitle
        : widget.strings.runtimeBlockedTitle;
    final summary = widget.allowContinue
        ? widget.strings.runtimeWarningsMessage
        : widget.strings.runtimeBlockedMessage;

    return Dialog(
      key: const ValueKey('runtime-health-dialog'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: compact ? 8 : 16,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxDialogHeight),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    widget.allowContinue
                        ? Icons.warning_amber_rounded
                        : Icons.gpp_bad_outlined,
                    color: widget.allowContinue
                        ? colorScheme.tertiary
                        : colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: compact
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 8 : 14),
              Flexible(
                child: ListView.builder(
                  key: const ValueKey('runtime-health-issues'),
                  shrinkWrap: true,
                  itemCount: widget.report.issues.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(summary),
                      );
                    }
                    final issue = widget.report.issues[index - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _RuntimeHealthIssueCard(
                        issue: issue,
                        strings: widget.strings,
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: compact ? 4 : 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    key: const ValueKey('runtime-health-close'),
                    height: 48,
                    child: TextButton(
                      onPressed: _closing || _openingSettings
                          ? null
                          : () => _finish(false),
                      child: Text(widget.strings.close),
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('runtime-health-settings'),
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _closing || _openingSettings
                          ? null
                          : _openSystemSettings,
                      icon: _openingSettings
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.settings_outlined, size: 18),
                      label: Text(widget.strings.runtimeSystemSettings),
                    ),
                  ),
                  if (widget.allowContinue)
                    SizedBox(
                      key: const ValueKey('runtime-health-continue'),
                      height: 48,
                      child: FilledButton(
                        onPressed: _closing || _openingSettings
                            ? null
                            : () => _finish(true),
                        child: Text(widget.strings.runtimeContinue),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuntimeHealthIssueCard extends StatelessWidget {
  final ClientRuntimeHealthIssue issue;
  final AiStrings strings;

  const _RuntimeHealthIssueCard({required this.issue, required this.strings});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final blocking = issue.severity == ClientRuntimeHealthStatus.blocking;
    final localized = strings.runtimeHealthIssue(issue);
    final severity = blocking
        ? strings.runtimeBlockingLabel
        : strings.runtimeWarningLabel;
    final accent = blocking ? colorScheme.error : colorScheme.tertiary;

    return Semantics(
      key: ValueKey('runtime-health-issue-${issue.code}'),
      container: true,
      label:
          '$severity: ${localized.title}. ${localized.detail} ${localized.recommendation}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            border: Border.all(color: accent.withValues(alpha: 0.24)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                blocking
                    ? Icons.error_outline_rounded
                    : Icons.warning_amber_rounded,
                size: 20,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          localized.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            severity,
                            style: TextStyle(
                              color: accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      localized.detail,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      localized.recommendation,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
