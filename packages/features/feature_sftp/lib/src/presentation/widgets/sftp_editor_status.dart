part of '../sftp_editor_screen.dart';

class _EditorLoading extends StatelessWidget {
  const _EditorLoading({required this.strings});

  final SftpStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppSkeletonizer.zone(
      key: const ValueKey('sftp-editor-loading'),
      enabled: true,
      semanticsLabel: strings.loadingRemoteFile,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.pagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Summary Card
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const AppIconBadge(
                      icon: Icons.edit_note_rounded,
                      size: 42,
                      iconSize: 21,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'main.py',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '/var/www/service/main.py',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusPill,
                        ),
                      ),
                      child: const Text(
                        'UTF-8 · Python',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Editor Canvas
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Line numbers
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(
                        12,
                        (i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    const VerticalDivider(width: 1),
                    const SizedBox(width: 16),

                    // Code lines
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '#!/usr/bin/env python3',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              'import os, sys, asyncio',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              'async def bootstrap():',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '    server = await create_server(host="0.0.0.0", port=8000)',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '    print("Server initialized successfully")',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '    await server.serve_forever()',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              'if __name__ == "__main__":',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '    asyncio.run(bootstrap())',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorLoadError extends StatelessWidget {
  const _EditorLoadError({required this.strings, required this.onRetry});

  final SftpStrings strings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Semantics(
            key: const ValueKey('sftp-editor-load-error'),
            container: true,
            explicitChildNodes: true,
            liveRegion: true,
            label:
                '${strings.remoteFileOpenFailed}. '
                '${strings.remoteFileOpenFailedHint}',
            child: AppEmptyState(
              icon: Icons.cloud_off_rounded,
              title: strings.remoteFileOpenFailed,
              message: strings.remoteFileOpenFailedHint,
              action: FilledButton.icon(
                key: const ValueKey('sftp-editor-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(strings.retry),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileSummaryCard extends StatelessWidget {
  const _FileSummaryCard({
    required this.entry,
    required this.strings,
    required this.hasUnsavedChanges,
  });

  final SftpEntry entry;
  final SftpStrings strings;
  final bool hasUnsavedChanges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      key: const ValueKey('sftp-editor-file-summary'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fileDetails = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const AppIconBadge(
                  icon: Icons.code_rounded,
                  size: 42,
                  iconSize: 21,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Semantics(
                        key: const ValueKey('sftp-editor-path'),
                        container: true,
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
            final status = _EditorStatusPill(
              strings: strings,
              hasUnsavedChanges: hasUnsavedChanges,
            );

            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fileDetails,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: status),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: fileDetails),
                const SizedBox(width: 16),
                status,
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
    required this.strings,
    required this.hasUnsavedChanges,
  });

  final SftpEntry entry;
  final SftpStrings strings;
  final bool hasUnsavedChanges;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final extended = Theme.of(context).extension<ExtendedColors>();
    final accent = hasUnsavedChanges
        ? (extended?.warning ?? colors.tertiary)
        : (extended?.success ?? colors.secondary);
    final status = hasUnsavedChanges
        ? strings.remoteFileUnsaved
        : strings.remoteFileSaved;

    return Semantics(
      key: const ValueKey('sftp-editor-compact-summary'),
      container: true,
      liveRegion: true,
      label: '${strings.remoteFilePath}: ${entry.path}. $status',
      child: ExcludeSemantics(
        child: Card(
          margin: EdgeInsets.zero,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.code_rounded, size: 20, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFamily: 'monospace',
                        fontFamilyFallback: AppTheme.monospaceFallback,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    hasUnsavedChanges
                        ? Icons.edit_note_rounded
                        : Icons.cloud_done_rounded,
                    size: 20,
                    color: accent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorStatusPill extends StatelessWidget {
  const _EditorStatusPill({
    required this.strings,
    required this.hasUnsavedChanges,
  });

  final SftpStrings strings;
  final bool hasUnsavedChanges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final extended = theme.extension<ExtendedColors>();
    final accent = hasUnsavedChanges
        ? (extended?.warning ?? colors.tertiary)
        : (extended?.success ?? colors.secondary);
    final label = hasUnsavedChanges
        ? strings.remoteFileUnsaved
        : strings.remoteFileSaved;

    return Semantics(
      key: const ValueKey('sftp-editor-save-status'),
      container: true,
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
            border: Border.all(color: accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasUnsavedChanges
                    ? Icons.edit_note_rounded
                    : Icons.cloud_done_rounded,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
