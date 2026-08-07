part of 'sftp_screen.dart';

class _SftpFileToolbar extends StatelessWidget {
  const _SftpFileToolbar({
    required this.strings,
    required this.currentPath,
    required this.disabled,
    required this.onParent,
    required this.onPath,
    required this.onRefresh,
    required this.onUpload,
    required this.onDisconnect,
    required this.onSettings,
  });

  final SftpStrings strings;
  final String currentPath;
  final bool disabled;
  final VoidCallback onParent;
  final VoidCallback onPath;
  final VoidCallback onRefresh;
  final VoidCallback onUpload;
  final VoidCallback onDisconnect;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final uploadDisabledBackground = colors.onSurface.withValues(alpha: 0.12);
    final uploadDisabledForeground = colors.onSurface.withValues(alpha: 0.38);
    return DecoratedBox(
      key: const ValueKey('sftp-file-toolbar'),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.88),
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final expanded = constraints.maxWidth >= 720 && textScale < 1.5;
          final path = _SftpPathButton(
            strings: strings,
            path: currentPath,
            enabled: !disabled,
            onPressed: onPath,
          );
          final parent = _SftpToolbarIconButton(
            key: const ValueKey('sftp-parent-directory'),
            tooltip: strings.parentDirectory,
            icon: Icons.drive_folder_upload_outlined,
            onPressed: disabled ? null : onParent,
          );
          final history = _SftpToolbarIconButton(
            key: const ValueKey('sftp-path-history'),
            tooltip: strings.pathHistory,
            icon: Icons.star_outline_rounded,
            onPressed: disabled ? null : onPath,
          );
          final refresh = _SftpToolbarIconButton(
            key: const ValueKey('sftp-refresh-directory'),
            tooltip: strings.refresh,
            icon: Icons.refresh_rounded,
            onPressed: disabled ? null : onRefresh,
          );
          final disconnect = _SftpToolbarIconButton(
            key: const ValueKey('sftp-disconnect'),
            tooltip: strings.disconnect,
            icon: Icons.link_off_rounded,
            color: colors.error,
            onPressed: onDisconnect,
          );
          final settings = _SftpToolbarIconButton(
            tooltip: strings.sftpSettings,
            icon: Icons.settings_outlined,
            onPressed: onSettings,
          );
          final upload = ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: FilledButton.icon(
              key: const ValueKey('sftp-upload-file'),
              onPressed: disabled ? null : onUpload,
              style: FilledButton.styleFrom(
                backgroundColor: colors.secondary,
                foregroundColor: colors.onSecondary,
                disabledBackgroundColor: uploadDisabledBackground,
                disabledForegroundColor: uploadDisabledForeground,
              ),
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(
                strings.uploadFile,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
          final compactUpload = SizedBox.square(
            dimension: 48,
            child: IconButton.filled(
              key: const ValueKey('sftp-upload-file'),
              tooltip: strings.uploadFile,
              onPressed: disabled ? null : onUpload,
              style: IconButton.styleFrom(
                backgroundColor: colors.secondary,
                foregroundColor: colors.onSecondary,
                disabledBackgroundColor: uploadDisabledBackground,
                disabledForegroundColor: uploadDisabledForeground,
              ),
              icon: const Icon(Icons.upload_file_rounded),
            ),
          );

          return Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              expanded ? 12 : 8,
              12,
              expanded ? 12 : 8,
            ),
            child: expanded
                ? Row(
                    children: [
                      parent,
                      const SizedBox(width: 8),
                      Expanded(child: path),
                      const SizedBox(width: 8),
                      history,
                      const SizedBox(width: 4),
                      refresh,
                      const SizedBox(width: 8),
                      upload,
                      const SizedBox(width: 4),
                      settings,
                      const SizedBox(width: 4),
                      disconnect,
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          parent,
                          const SizedBox(width: 6),
                          Expanded(child: path),
                          const SizedBox(width: 4),
                          refresh,
                          const SizedBox(width: 4),
                          compactUpload,
                          const SizedBox(width: 4),
                          PopupMenuButton<String>(
                            key: const ValueKey('sftp-disconnect'),
                            tooltip: strings.moreActions,
                            onSelected: (value) {
                              if (value == 'history') onPath();
                              if (value == 'settings') onSettings();
                              if (value == 'disconnect') onDisconnect();
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'history',
                                child: Text(strings.pathHistory),
                              ),
                              PopupMenuItem(
                                value: 'settings',
                                child: Text(strings.sftpSettings),
                              ),
                              PopupMenuItem(
                                value: 'disconnect',
                                child: Text(strings.disconnect),
                              ),
                            ],
                            child: const SizedBox.square(
                              dimension: 48,
                              child: Icon(Icons.more_vert_rounded),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _SftpPathButton extends StatelessWidget {
  const _SftpPathButton({
    required this.strings,
    required this.path,
    required this.enabled,
    required this.onPressed,
  });

  final SftpStrings strings;
  final String path;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final action = enabled ? onPressed : null;
    return Semantics(
      key: const ValueKey('sftp-path-button'),
      container: true,
      button: true,
      enabled: enabled,
      label: '${strings.inputPath}: $path',
      onTap: action,
      child: ExcludeSemantics(
        child: Material(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            side: BorderSide(color: colors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: action,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      size: 20,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: OverflowScrollText(
                        path,
                        selectable: false,
                        maxLines: 1,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.edit_outlined,
                      size: 17,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SftpToolbarIconButton extends StatelessWidget {
  const _SftpToolbarIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: color),
      ),
    );
  }
}

class _SftpDirectoryErrorCard extends StatelessWidget {
  const _SftpDirectoryErrorCard({
    required this.strings,
    required this.message,
    required this.onRetry,
  });

  final SftpStrings strings;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return Semantics(
      key: const ValueKey('sftp-directory-error'),
      container: true,
      liveRegion: true,
      label: '${strings.directoryLoadFailed}. $message',
      child: ExcludeSemantics(
        child: Card(
          color: Color.alphaBlend(
            colors.error.withValues(alpha: 0.08),
            colors.surfaceContainerLow,
          ),
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 520 || textScale >= 1.5;
              final details = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIconBadge(
                    icon: Icons.cloud_off_rounded,
                    size: 40,
                    iconSize: 20,
                    color: colors.error,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          strings.directoryLoadFailed,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: colors.error,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          message.isEmpty
                              ? strings.directoryLoadFailedHint
                              : message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              final retry = FilledButton.tonalIcon(
                key: const ValueKey('sftp-directory-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(strings.retry),
              );
              return Padding(
                padding: const EdgeInsets.all(14),
                child: compact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          details,
                          const SizedBox(height: 12),
                          Align(alignment: Alignment.centerRight, child: retry),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: details),
                          const SizedBox(width: 16),
                          retry,
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}
