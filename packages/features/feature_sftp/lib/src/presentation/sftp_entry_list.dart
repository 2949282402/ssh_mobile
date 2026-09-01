part of 'sftp_screen.dart';

final _kPlaceholderSftpEntries = [
  const SftpEntry(
    connectionId: 'placeholder',
    targetFingerprint: 'placeholder',
    path: '/documents',
    name: 'documents',
    lowerName: 'documents',
    sizeLabel: '4 KB',
    size: 4096,
    isDirectory: true,
    isLink: false,
  ),
  const SftpEntry(
    connectionId: 'placeholder',
    targetFingerprint: 'placeholder',
    path: '/downloads',
    name: 'downloads',
    lowerName: 'downloads',
    sizeLabel: '4 KB',
    size: 4096,
    isDirectory: true,
    isLink: false,
  ),
  const SftpEntry(
    connectionId: 'placeholder',
    targetFingerprint: 'placeholder',
    path: '/server_config.yaml',
    name: 'server_config.yaml',
    lowerName: 'server_config.yaml',
    sizeLabel: '12.4 KB',
    size: 12400,
    isDirectory: false,
    isLink: false,
  ),
  const SftpEntry(
    connectionId: 'placeholder',
    targetFingerprint: 'placeholder',
    path: '/docker-compose.yml',
    name: 'docker-compose.yml',
    lowerName: 'docker-compose.yml',
    sizeLabel: '3.2 KB',
    size: 3200,
    isDirectory: false,
    isLink: false,
  ),
  const SftpEntry(
    connectionId: 'placeholder',
    targetFingerprint: 'placeholder',
    path: '/deploy.sh',
    name: 'deploy.sh',
    lowerName: 'deploy.sh',
    sizeLabel: '1.8 KB',
    size: 1820,
    isDirectory: false,
    isLink: false,
  ),
  const SftpEntry(
    connectionId: 'placeholder',
    targetFingerprint: 'placeholder',
    path: '/app.log',
    name: 'app.log',
    lowerName: 'app.log',
    sizeLabel: '1.0 MB',
    size: 1048576,
    isDirectory: false,
    isLink: false,
  ),
];

class _SftpEntryList extends StatelessWidget {
  final SftpStrings strings;
  final SftpViewModel sftp;
  final bool busy;
  final Future<void> Function(
    BuildContext context,
    String action,
    SftpEntry entry,
  )
  onEntryAction;
  final String Function(SftpStrings strings, SftpEntry entry) entryMeta;

  const _SftpEntryList({
    required this.strings,
    required this.sftp,
    required this.busy,
    required this.onEntryAction,
    required this.entryMeta,
  });

  @override
  Widget build(BuildContext context) {
    final scale = mobileUiScaleOf(context);
    final snapshot = context.select<SftpViewModel, _SftpEntriesSnapshot>(
      _SftpEntriesSnapshot.from,
    );
    final entries = snapshot.entries;
    if (busy && entries.isEmpty) {
      return _SftpDirectoryLoadingState(strings: strings);
    }
    if (entries.isEmpty) {
      return LayoutBuilder(
        key: const ValueKey('sftp-directory-empty'),
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: AppEmptyState(
              icon: Icons.create_new_folder_outlined,
              title: strings.emptyDirectory,
              message: strings.emptyDirectoryHint,
              compact: true,
              contained: false,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      scrollCacheExtent: const ScrollCacheExtent.pixels(900.0),
      padding: EdgeInsets.fromLTRB(
        12 * scale,
        12 * scale,
        12 * scale,
        28 * scale + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final meta = entryMeta(strings, entry);
        return RepaintBoundary(
          key: ValueKey('${entry.connectionId}:${entry.path}'),
          child: Builder(
            builder: (innerContext) {
              return _SftpEntryTile(
                strings: strings,
                entry: entry,
                meta: meta,
                busy: busy,
                useHero: entries.length <= 100,
                onTap: busy
                    ? null
                    : entry.isDirectory
                    ? () => sftp.openPath(entry.path)
                    : () => onEntryAction(innerContext, 'view', entry),
                onLongPress: busy
                    ? null
                    : () => _showContextMenu(innerContext, entry),
                onSelected: (action) =>
                    onEntryAction(innerContext, action, entry),
                menuBuilder: (_) => _buildMenuItems(innerContext, entry),
              );
            },
          ),
        );
      },
    );
  }

  List<PopupMenuEntry<String>> _buildMenuItems(
    BuildContext context,
    SftpEntry entry,
  ) {
    return [
      if (!entry.isDirectory)
        PopupMenuItem(
          value: 'view',
          child: Row(
            children: [
              const Icon(Icons.visibility_outlined, size: 18),
              const SizedBox(width: 8),
              Text(strings.viewFile),
            ],
          ),
        ),
      if (!entry.isDirectory)
        PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              const Icon(Icons.edit_outlined, size: 18),
              const SizedBox(width: 8),
              Text(strings.edit),
            ],
          ),
        ),
      if (!entry.isDirectory)
        PopupMenuItem(
          value: 'download',
          child: Row(
            children: [
              const Icon(Icons.download_rounded, size: 18),
              const SizedBox(width: 8),
              Text(strings.downloadFile),
            ],
          ),
        ),
      PopupMenuItem(
        value: 'delete',
        child: Row(
          children: [
            Icon(
              Icons.delete_outline,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 8),
            Text(
              strings.delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      ),
    ];
  }

  void _showContextMenu(BuildContext context, SftpEntry entry) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);

    final position = RelativeRect.fromLTRB(
      offset.dx + 40,
      offset.dy + size.height / 2,
      offset.dx + size.width,
      offset.dy + size.height,
    );

    showMenu<String>(
      context: context,
      position: position,
      items: _buildMenuItems(context, entry),
    ).then((action) {
      if (action != null && context.mounted) {
        onEntryAction(context, action, entry);
      }
    });
  }
}

class _SftpDirectoryLoadingState extends StatelessWidget {
  const _SftpDirectoryLoadingState({required this.strings});

  final SftpStrings strings;

  @override
  Widget build(BuildContext context) {
    final scale = mobileUiScaleOf(context);
    return AppSkeletonizer(
      key: const ValueKey('sftp-directory-loading'),
      enabled: true,
      semanticsLabel: strings.loadingDirectory,
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          12 * scale,
          12 * scale,
          12 * scale,
          28 * scale + MediaQuery.viewPaddingOf(context).bottom,
        ),
        itemCount: _kPlaceholderSftpEntries.length,
        itemBuilder: (context, index) {
          final entry = _kPlaceholderSftpEntries[index];
          return _SftpEntryTile(
            strings: strings,
            entry: entry,
            meta: entry.isDirectory ? 'Directory · 4 KB' : '12.4 KB · 2026-09-01',
            busy: true,
            useHero: false,
            onTap: null,
            onLongPress: null,
            onSelected: (_) {},
            menuBuilder: (_) => const [],
          );
        },
      ),
    );
  }
}

class _SftpEntryTile extends StatelessWidget {
  const _SftpEntryTile({
    required this.strings,
    required this.entry,
    required this.meta,
    required this.busy,
    required this.useHero,
    required this.onTap,
    required this.onLongPress,
    required this.onSelected,
    required this.menuBuilder,
  });

  final SftpStrings strings;
  final SftpEntry entry;
  final String meta;
  final bool busy;
  final bool useHero;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<String> onSelected;
  final PopupMenuItemBuilder<String> menuBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final scale = mobileUiScaleOf(context);
    final icon = entry.isDirectory
        ? Icons.folder_rounded
        : entry.isLink
        ? Icons.shortcut_rounded
        : Icons.description_outlined;
    final iconColor = entry.isDirectory
        ? colors.primary
        : entry.isLink
        ? colors.tertiary
        : colors.onSurfaceVariant;
    final title = OverflowScrollText(
      entry.name,
      selectable: false,
      maxLines: 1,
      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
    );
    final titleWidget = useHero
        ? Hero(
            tag: 'sftp_file_${entry.connectionId}_${entry.path}',
            child: Material(type: MaterialType.transparency, child: title),
          )
        : title;

    return Semantics(
      key: ValueKey('sftp-entry-${entry.connectionId}:${entry.path}'),
      container: true,
      button: true,
      enabled: !busy,
      label: '${entry.name}, $meta',
      onTap: onTap,
      onLongPress: onLongPress,
      child: TactileFeedback(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 480 ||
                  MediaQuery.textScalerOf(context).scale(1) >= 1.5;
              return Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 8 * scale,
                  vertical: 6 * scale,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: 0.62),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 28 * scale,
                      child: Center(
                        child: Icon(icon, size: 20 * scale, color: iconColor),
                      ),
                    ),
                    SizedBox(width: 8 * scale),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          titleWidget,
                          SizedBox(height: 2 * scale),
                          OverflowScrollText(
                            meta,
                            selectable: false,
                            maxLines: 1,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 6 * scale),
                    if (entry.isDirectory && !compact)
                      Icon(
                        Icons.chevron_right_rounded,
                        color: colors.onSurfaceVariant,
                      ),
                    SizedBox.square(
                      dimension: 48,
                      child: PopupMenuButton<String>(
                        key: ValueKey(
                          'sftp-entry-actions-${entry.connectionId}:${entry.path}',
                        ),
                        tooltip: strings.entryActions(entry.name),
                        enabled: !busy,
                        icon: const Icon(Icons.more_horiz_rounded),
                        onSelected: onSelected,
                        itemBuilder: menuBuilder,
                      ),
                    ),
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

class _SftpEmptyState extends StatelessWidget {
  final SftpStrings strings;

  const _SftpEmptyState({required this.strings});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => AppEmptyState(
        icon: Icons.folder_open_rounded,
        title: strings.sftpEmptyTitle,
        message: strings.sftpEmptyHint,
        compact: constraints.maxWidth < 420,
      ),
    );
  }
}

class _SftpTransferBanner extends StatelessWidget {
  final SftpStrings strings;
  final SftpViewModel sftp;
  final SftpTransferState activeTransfer;

  const _SftpTransferBanner({
    required this.strings,
    required this.sftp,
    required this.activeTransfer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isUpload = activeTransfer.isUpload;
    final progress = activeTransfer.progress.clamp(0.0, 1.0).toDouble();
    final totalBytes = activeTransfer.totalBytes;
    final transferredBytes = activeTransfer.bytesTransferred;
    final accent = activeTransfer.isError
        ? colorScheme.error
        : colorScheme.primary;

    final title = isUpload
        ? strings.uploadingFile(activeTransfer.name)
        : strings.downloadingFile(activeTransfer.name);

    final percent = (progress * 100).round();
    final percentText = totalBytes > 0 ? '$percent%' : '';

    final sizeText =
        '${_formatBytes(transferredBytes)}${totalBytes > 0 ? ' / ${_formatBytes(totalBytes)}' : ''}';

    return Semantics(
      key: const ValueKey('sftp-transfer-banner'),
      container: true,
      liveRegion: true,
      label: title,
      value: [
        percentText,
        sizeText,
      ].where((value) => value.isNotEmpty).join(', '),
      child: ExcludeSemantics(
        child: Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          color: Color.alphaBlend(
            accent.withValues(alpha: 0.07),
            colorScheme.surfaceContainerLow,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 520 ||
                  MediaQuery.textScalerOf(context).scale(1) >= 1.5;
              final progressDetails = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: totalBytes > 0 ? progress : null,
                    minHeight: 5,
                    color: accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 6),
                  if (compact)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          sizeText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (percentText.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            percentText,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            sizeText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (percentText.isNotEmpty) ...[
                          const SizedBox(width: 12),
                          Text(
                            percentText,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ],
                    ),
                ],
              );

              return Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AppIconBadge(
                      icon: isUpload
                          ? Icons.upload_file_rounded
                          : Icons.downloading_rounded,
                      size: 42,
                      iconSize: 21,
                      color: accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: progressDetails),
                    const SizedBox(width: 10),
                    SizedBox.square(
                      dimension: 48,
                      child: IconButton.filledTonal(
                        key: const ValueKey('sftp-cancel-transfer'),
                        icon: Icon(
                          Icons.close_rounded,
                          color: colorScheme.error,
                        ),
                        tooltip: strings.cancel,
                        onPressed: activeTransfer.isCancelled
                            ? null
                            : sftp.cancelActiveTransfer,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '-';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
  }
}
