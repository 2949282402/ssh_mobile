part of 'sftp_screen.dart';

class _FilePane extends StatelessWidget {
  final AppStrings strings;
  final SftpViewModel sftp;

  const _FilePane({required this.strings, required this.sftp});

  @override
  Widget build(BuildContext context) {
    final snapshot = context.select<SftpViewModel, _SftpPaneStatusSnapshot>(
      _SftpPaneStatusSnapshot.from,
    );

    if (snapshot.state == SftpConnectionState.disconnected) {
      return _SftpEmptyState(strings: strings);
    }

    return Column(
      children: [
        _SftpFileToolbar(
          strings: strings,
          currentPath: snapshot.currentPath,
          disabled: snapshot.isBusy,
          onParent: sftp.openParent,
          onPath: () =>
              _showPathHistorySheet(context, sftp, snapshot.currentPath),
          onRefresh: sftp.refresh,
          onUpload: () => _uploadFile(context),
          onDisconnect: sftp.disconnect,
        ),
        if (snapshot.isBusy && snapshot.activeTransfer == null)
          Semantics(
            label: strings.loadingDirectory,
            child: const LinearProgressIndicator(minHeight: 2),
          ),
        if (snapshot.activeTransfer != null)
          _SftpTransferBanner(
            strings: strings,
            sftp: sftp,
            activeTransfer: snapshot.activeTransfer!,
          ),
        if (snapshot.state == SftpConnectionState.error &&
            snapshot.errorMessage != null)
          _SftpDirectoryErrorCard(
            strings: strings,
            message: snapshot.errorMessage!,
            onRetry: sftp.refresh,
          ),
        Expanded(
          child: _SftpEntryList(
            strings: strings,
            sftp: sftp,
            busy: snapshot.isBusy,
            onEntryAction: _handleEntryAction,
            entryMeta: _entryMeta,
          ),
        ),
      ],
    );
  }
}

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
  });

  final AppStrings strings;
  final String currentPath;
  final bool disabled;
  final VoidCallback onParent;
  final VoidCallback onPath;
  final VoidCallback onRefresh;
  final VoidCallback onUpload;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    const uploadColor = Color(0xFF4338CA);
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
          final upload = ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: FilledButton.icon(
              key: const ValueKey('sftp-upload-file'),
              onPressed: disabled ? null : onUpload,
              style: FilledButton.styleFrom(
                backgroundColor: uploadColor,
                foregroundColor: Colors.white,
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
                backgroundColor: uploadColor,
                foregroundColor: Colors.white,
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
                          disconnect,
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

  final AppStrings strings;
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

  final AppStrings strings;
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

extension _SftpFilePaneActions on _FilePane {
  Future<void> _uploadFile(BuildContext context) async {
    final sftp = context.read<SftpViewModel>();
    final settings = context.read<AppSettings>();
    final strings = AppStrings(settings.language);
    final messenger = ScaffoldMessenger.of(context);

    final file = await FilePicker.pickFile();
    if (file == null) return;

    if (file.size > SftpService.maxUploadBytes) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.uploadFailed(
              strings.uploadFileTooLarge(
                _formatBytes(SftpService.maxUploadBytes),
              ),
            ),
          ),
        ),
      );
      return;
    }

    final localPath = file.path;
    if (localPath == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(strings.uploadFailed(strings.uploadFileNoAccess)),
        ),
      );
      return;
    }

    final filename = file.name.isNotEmpty ? file.name : p.basename(localPath);

    try {
      await sftp.uploadLocalFile(
        localPath: localPath,
        filename: filename,
        sizeBytes: file.size,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.uploadComplete)));
    } catch (e) {
      if (!context.mounted) return;
      if (e is SftpTransferCancelledException) {
        messenger.showSnackBar(
          SnackBar(content: Text(strings.uploadCancelled)),
        );
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text(strings.uploadFailed(e))));
    }
  }

  Future<void> _handleEntryAction(
    BuildContext context,
    String action,
    SftpEntry entry,
  ) async {
    switch (action) {
      case 'view':
        await _viewFile(context, entry);
        break;
      case 'edit':
        await _editFile(context, entry);
        break;
      case 'download':
        await _downloadFile(context, entry);
        break;
      case 'delete':
        await _confirmDelete(context, entry);
        break;
    }
  }

  Future<void> _viewFile(BuildContext context, SftpEntry entry) async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) =>
            SharedAxisTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              transitionType: SharedAxisTransitionType.scaled,
              child: SftpFileViewerScreen(entry: entry),
            ),
      ),
    );
  }

  Future<void> _downloadFile(BuildContext context, SftpEntry entry) async {
    final settings = context.read<AppSettings>();
    final strings = AppStrings(settings.language);
    final sftp = context.read<SftpViewModel>();
    final messenger = ScaffoldMessenger.of(context);

    if (entry.size != null && entry.size! > settings.sftpDownloadLimitBytes) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.downloadFailed(
              strings.downloadFileTooLarge(
                _formatBytes(settings.sftpDownloadLimitBytes),
              ),
            ),
          ),
        ),
      );
      return;
    }

    try {
      final savedPath = await FilePicker.saveFile(
        dialogTitle: strings.downloadFile,
        fileName: entry.name,
        bytes: Uint8List(0),
      );
      if (savedPath == null) return;

      await sftp.downloadToLocalFile(
        entry: entry,
        localPath: savedPath,
        maxBytes: settings.sftpDownloadLimitBytes,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.downloadComplete)));
    } catch (e) {
      if (!context.mounted) return;
      if (e is SftpTransferCancelledException) {
        messenger.showSnackBar(
          SnackBar(content: Text(strings.downloadCancelled)),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(strings.downloadFailed(e))),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, SftpEntry entry) async {
    final settings = context.read<AppSettings>();
    final strings = AppStrings(settings.language);
    final sftp = context.read<SftpViewModel>();
    final nameController = TextEditingController();
    String? errorText;
    final confirmedName = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(strings.deleteRemoteEntry),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.deleteRemoteEntryContent(entry.name)),
                const SizedBox(height: 14),
                Text(
                  strings.deleteRemoteEntryConfirmPrompt,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  entry.name,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: strings.deleteRemoteEntryConfirmLabel,
                    errorText: errorText,
                  ),
                  onChanged: (_) {
                    if (errorText != null) {
                      setDialogState(() => errorText = null);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(strings.cancel),
            ),
            TextButton(
              onPressed: () {
                final typedName = nameController.text;
                if (typedName != entry.name && typedName.trim() != entry.name) {
                  setDialogState(() {
                    errorText = strings.deleteRemoteEntryConfirmMismatch;
                  });
                  return;
                }
                Navigator.pop(ctx, typedName);
              },
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(strings.delete),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    if (confirmedName != null) {
      await sftp.deleteEntry(entry, confirmedName: confirmedName);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.deleteComplete)));
    }
  }

  Future<void> _editFile(BuildContext context, SftpEntry entry) async {
    await Navigator.push<bool>(
      context,
      PageRouteBuilder<bool>(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) =>
            SharedAxisTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              transitionType: SharedAxisTransitionType.scaled,
              child: SftpEditorScreen(entry: entry),
            ),
      ),
    );
  }

  String _entryMeta(AppStrings strings, SftpEntry entry) {
    final parts = <String>[];
    parts.add(entry.isDirectory ? strings.directory : entry.sizeLabel);
    final modifiedLabel = entry.modifiedLabel;
    if (modifiedLabel != null) parts.add(modifiedLabel);
    return parts.join(' | ');
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

  void _showPathHistorySheet(
    BuildContext context,
    SftpViewModel sftp,
    String currentPath,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SftpPathHistorySheet(
        strings: strings,
        sftp: sftp,
        currentPath: currentPath,
      ),
    );
  }
}

class _SftpPathHistorySheet extends StatefulWidget {
  final AppStrings strings;
  final SftpViewModel sftp;
  final String currentPath;

  const _SftpPathHistorySheet({
    required this.strings,
    required this.sftp,
    required this.currentPath,
  });

  @override
  State<_SftpPathHistorySheet> createState() => _SftpPathHistorySheetState();
}

class _SftpPathHistorySheetState extends State<_SftpPathHistorySheet> {
  late Future<_SftpPathHistoryData> _future = _load();
  late final TextEditingController _pathController = TextEditingController(
    text: widget.currentPath,
  );

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<_SftpPathHistoryData> _load() async {
    final favorites = await widget.sftp.loadFavoritePaths();
    final recent = await widget.sftp.loadRecentPaths();
    final currentFavorite = await widget.sftp.findFavoritePath(
      widget.currentPath,
    );
    return _SftpPathHistoryData(
      recent: recent,
      favorites: favorites,
      currentFavorite: currentFavorite,
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final remainingHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.viewPadding.vertical;
    final availableHeight = remainingHeight > 0 ? remainingHeight * 0.86 : 0.0;
    final sheetHeight = availableHeight > 680 ? 680.0 : availableHeight;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SizedBox(
              height: sheetHeight,
              child: FutureBuilder<_SftpPathHistoryData>(
                future: _future,
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  final waiting =
                      snapshot.connectionState == ConnectionState.waiting;
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 2, 12, 10),
                        child: AppPageHeader(
                          title: widget.strings.pathHistory,
                          icon: Icons.route_rounded,
                          trailing: SizedBox.square(
                            dimension: 48,
                            child: IconButton.filledTonal(
                              key: const ValueKey('sftp-toggle-favorite'),
                              tooltip: data?.currentFavorite == null
                                  ? widget.strings.addFavoritePath
                                  : widget.strings.removeFavoritePath,
                              icon: Icon(
                                data?.currentFavorite == null
                                    ? Icons.star_outline_rounded
                                    : Icons.star_rounded,
                                color: data?.currentFavorite == null
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.primary,
                              ),
                              onPressed: waiting || snapshot.hasError
                                  ? null
                                  : () =>
                                        _toggleFavorite(data?.currentFavorite),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: TextField(
                          key: const ValueKey('sftp-path-input'),
                          controller: _pathController,
                          decoration: InputDecoration(
                            labelText: widget.strings.inputPath,
                            prefixIcon: const Icon(Icons.folder_open_rounded),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            suffixIcon: SizedBox.square(
                              key: const ValueKey('sftp-open-path'),
                              dimension: 48,
                              child: IconButton(
                                tooltip: widget.strings.openPath,
                                icon: const Icon(Icons.arrow_forward_rounded),
                                onPressed: _openTypedPath,
                              ),
                            ),
                          ),
                          textInputAction: TextInputAction.go,
                          onSubmitted: (_) => _openTypedPath(),
                        ),
                      ),
                      Divider(height: 1, color: colorScheme.outlineVariant),
                      if (waiting)
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            label: widget.strings.pathHistory,
                            child: const Center(
                              child: SizedBox.square(
                                dimension: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                        )
                      else if (snapshot.hasError)
                        Expanded(
                          child: AppEmptyState(
                            icon: Icons.history_toggle_off_rounded,
                            title: widget.strings.pathHistoryLoadFailed,
                            message: widget.strings.pathHistoryLoadFailedHint,
                            compact: true,
                            contained: false,
                            action: FilledButton.tonalIcon(
                              key: const ValueKey('sftp-path-history-retry'),
                              onPressed: _reload,
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(widget.strings.retry),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                            children: [
                              _SftpPathSectionHeader(
                                label: widget.strings.favoritePaths,
                              ),
                              if (data == null || data.favorites.isEmpty)
                                _EmptyPathRow(
                                  label: widget.strings.noFavoritePaths,
                                )
                              else
                                for (final favorite in data.favorites)
                                  _PathListTile(
                                    icon: Icons.star_rounded,
                                    label: favorite.name,
                                    path: favorite.path,
                                    trailing: SizedBox.square(
                                      dimension: 48,
                                      child: IconButton(
                                        tooltip:
                                            widget.strings.removeFavoritePath,
                                        icon: const Icon(Icons.close_rounded),
                                        onPressed: () =>
                                            _removeFavorite(favorite.id),
                                      ),
                                    ),
                                    onTap: () => _openPath(favorite.path),
                                  ),
                              const SizedBox(height: 8),
                              _SftpPathSectionHeader(
                                label: widget.strings.recentPaths,
                              ),
                              if (data == null || data.recent.isEmpty)
                                _EmptyPathRow(
                                  label: widget.strings.noRecentPaths,
                                )
                              else
                                for (final recent in data.recent)
                                  _PathListTile(
                                    icon: Icons.history_rounded,
                                    label: recent.path,
                                    path: _formatTimestamp(recent.visitedAt),
                                    onTap: () => _openPath(recent.path),
                                  ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openTypedPath() {
    final path = _pathController.text.trim();
    if (path.isNotEmpty) _openPath(path);
  }

  Future<void> _toggleFavorite(SftpFavoritePathRecord? favorite) async {
    try {
      if (favorite == null) {
        await widget.sftp.addFavoritePath(
          widget.currentPath,
          widget.currentPath,
        );
      } else {
        await widget.sftp.removeFavoritePath(favorite.id);
      }
      if (mounted) _reload();
    } catch (e) {
      _showHistoryError(e);
    }
  }

  Future<void> _removeFavorite(String id) async {
    try {
      await widget.sftp.removeFavoritePath(id);
      if (mounted) _reload();
    } catch (e) {
      _showHistoryError(e);
    }
  }

  void _showHistoryError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _openPath(String path) async {
    Navigator.pop(context);
    await widget.sftp.openPath(path);
  }

  String _formatTimestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year.toString().padLeft(4, '0')}-'
        '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _SftpPathHistoryData {
  final List<SftpRecentPathRecord> recent;
  final List<SftpFavoritePathRecord> favorites;
  final SftpFavoritePathRecord? currentFavorite;

  const _SftpPathHistoryData({
    required this.recent,
    required this.favorites,
    required this.currentFavorite,
  });
}

class _SftpPathSectionHeader extends StatelessWidget {
  final String label;

  const _SftpPathSectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _EmptyPathRow extends StatelessWidget {
  final String label;

  const _EmptyPathRow({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _PathListTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String path;
  final Widget? trailing;
  final VoidCallback onTap;

  const _PathListTile({
    required this.icon,
    required this.label,
    required this.path,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      button: true,
      label: '$label, $path',
      onTap: onTap,
      child: TactileFeedback(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(color: colors.outline.withValues(alpha: 0.58)),
            ),
            child: Row(
              children: [
                AppIconBadge(icon: icon, size: 36, iconSize: 18),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OverflowScrollText(
                        label,
                        selectable: false,
                        maxLines: 1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      OverflowScrollText(
                        path,
                        selectable: false,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing ??
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.onSurfaceVariant,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SftpEntryList extends StatelessWidget {
  final AppStrings strings;
  final SftpViewModel sftp;
  final bool busy;
  final Future<void> Function(
    BuildContext context,
    String action,
    SftpEntry entry,
  )
  onEntryAction;
  final String Function(AppStrings strings, SftpEntry entry) entryMeta;

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

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      key: const ValueKey('sftp-directory-loading'),
      container: true,
      liveRegion: true,
      label: strings.loadingDirectory,
      child: ExcludeSemantics(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Card(
              margin: const EdgeInsets.all(AppTheme.compactPagePadding),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 48,
                      child: CircularProgressIndicator(
                        key: const ValueKey('sftp-directory-loading-spinner'),
                        color: colors.primary,
                        strokeWidth: 2.4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      strings.loadingDirectory,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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

  final AppStrings strings;
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
                    AppIconBadge(
                      icon: icon,
                      size: 34 * scale,
                      iconSize: 18 * scale,
                      color: iconColor,
                    ),
                    SizedBox(width: 10 * scale),
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
  final AppStrings strings;

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
  final AppStrings strings;
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
