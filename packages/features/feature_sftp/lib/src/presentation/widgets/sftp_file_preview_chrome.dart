part of '../sftp_file_viewer_screen.dart';

class _FileSummaryCard extends StatelessWidget {
  const _FileSummaryCard({
    required this.entry,
    required this.kind,
    required this.strings,
  });

  final SftpEntry entry;
  final _PreviewKind kind;
  final SftpStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final details = strings.previewFileDetails(
      _previewKindLabel(kind, strings),
      entry.sizeLabel,
    );

    return Card(
      key: const ValueKey('sftp-viewer-file-summary'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fileDetails = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: AppIconBadge(
                    icon: _previewKindIcon(kind),
                    size: 42,
                    iconSize: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Semantics(
                        key: const ValueKey('sftp-viewer-path'),
                        label: '${strings.remoteFilePath}: ${entry.path}',
                        child: ExcludeSemantics(
                          child: Text(
                            entry.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontFamily: 'monospace',
                              fontFamilyFallback: AppTheme.monospaceFallback,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
            final pill = _PreviewTypePill(label: details);

            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fileDetails,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: pill),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: fileDetails),
                const SizedBox(width: 16),
                pill,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CompactFileSummary extends StatelessWidget {
  const _CompactFileSummary({
    required this.entry,
    required this.kind,
    required this.strings,
  });

  final SftpEntry entry;
  final _PreviewKind kind;
  final SftpStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final details = strings.previewFileDetails(
      _previewKindLabel(kind, strings),
      entry.sizeLabel,
    );

    return Card(
      key: const ValueKey('sftp-viewer-compact-summary'),
      margin: EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              ExcludeSemantics(
                child: AppIconBadge(
                  icon: _previewKindIcon(kind),
                  size: 36,
                  iconSize: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Semantics(
                      key: const ValueKey('sftp-viewer-path'),
                      label: '${strings.remoteFilePath}: ${entry.path}',
                      child: ExcludeSemantics(
                        child: Text(
                          entry.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontFamily: 'monospace',
                            fontFamilyFallback: AppTheme.monospaceFallback,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Flexible(child: _PreviewTypePill(label: details, compact: true)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewTypePill extends StatelessWidget {
  const _PreviewTypePill({required this.label, this.compact = false});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 9 : 11,
            vertical: compact ? 5 : 7,
          ),
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewModeToolbar extends StatelessWidget {
  const _PreviewModeToolbar({
    required this.strings,
    required this.showSource,
    required this.onChanged,
  });

  final SftpStrings strings;
  final bool showSource;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Semantics(
          label: strings.previewMode,
          container: true,
          child: SegmentedButton<bool>(
            key: const ValueKey('sftp-viewer-mode-toggle'),
            segments: [
              ButtonSegment<bool>(
                value: false,
                label: Text(
                  strings.preview,
                  key: const ValueKey('sftp-viewer-mode-preview'),
                ),
              ),
              ButtonSegment<bool>(
                value: true,
                label: Text(
                  strings.source,
                  key: const ValueKey('sftp-viewer-mode-source'),
                ),
              ),
            ],
            selected: {showSource},
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(0, 48)),
            ),
            onSelectionChanged: (selection) => onChanged(selection.single),
          ),
        ),
      ),
    );
  }
}

class _PreviewLoading extends StatelessWidget {
  const _PreviewLoading({required this.strings});

  final SftpStrings strings;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('sftp-viewer-loading'),
      container: true,
      liveRegion: true,
      label: strings.loadingFilePreview,
      child: ExcludeSemantics(
        child: _StateViewport(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppLoadingIndicator(
                  size: 30,
                  strokeWidth: 2.4,
                  semanticsLabel: strings.loadingFilePreview,
                ),
                const SizedBox(height: 16),
                Text(
                  strings.loadingFilePreview,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineLoading extends StatelessWidget {
  const _InlineLoading({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppLoadingIndicator(
        size: 24,
        strokeWidth: 2.2,
        semanticsLabel: label,
      ),
    );
  }
}

class _PreviewStateView extends StatelessWidget {
  const _PreviewStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondaryAction,
    this.liveRegion = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final Widget? secondaryAction;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: liveRegion,
      label: liveRegion ? '$title. $message' : null,
      explicitChildNodes: true,
      child: _StateViewport(
        child: AppEmptyState(
          icon: icon,
          title: title,
          message: message,
          action: action,
          secondaryAction: secondaryAction,
          compact: MediaQuery.sizeOf(context).height < 600,
          contained: false,
        ),
      ),
    );
  }
}

class _StateViewport extends StatelessWidget {
  const _StateViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: constraints.maxWidth,
              minHeight: constraints.maxHeight,
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.strings, required this.onPressed});

  final SftpStrings strings;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: const ValueKey('sftp-viewer-retry'),
      style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
      onPressed: onPressed,
      icon: const Icon(Icons.refresh_rounded),
      label: Text(strings.retry),
    );
  }
}

class _ClosePreviewButton extends StatelessWidget {
  const _ClosePreviewButton({required this.strings, required this.onPressed});

  final SftpStrings strings;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: const ValueKey('sftp-viewer-close'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
      onPressed: onPressed,
      icon: const Icon(Icons.arrow_back_rounded),
      label: Text(strings.closePreview),
    );
  }
}

class _LoggedRenderError extends StatefulWidget {
  const _LoggedRenderError({
    super.key,
    required this.error,
    required this.logMessage,
    required this.path,
    required this.strings,
    required this.onRetry,
    this.secondaryAction,
    this.stackTrace,
  });

  final Object error;
  final StackTrace? stackTrace;
  final String logMessage;
  final String path;
  final SftpStrings strings;
  final VoidCallback onRetry;
  final Widget? secondaryAction;

  @override
  State<_LoggedRenderError> createState() => _LoggedRenderErrorState();
}

class _LoggedRenderErrorState extends State<_LoggedRenderError> {
  @override
  void initState() {
    super.initState();
    _logError();
  }

  @override
  void didUpdateWidget(covariant _LoggedRenderError oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.error, widget.error)) _logError();
  }

  void _logError() {
    context.read<SftpLoggerPort?>()?.error(
      widget.logMessage,
      details: 'operation=preview_render code=operation_failed',
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PreviewStateView(
      liveRegion: true,
      icon: Icons.broken_image_outlined,
      title: widget.strings.filePreviewRenderFailed,
      message: widget.strings.filePreviewRenderFailedHint,
      action: _RetryButton(strings: widget.strings, onPressed: widget.onRetry),
      secondaryAction: widget.secondaryAction,
    );
  }
}
