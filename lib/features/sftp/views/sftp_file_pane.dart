part of 'sftp_screen.dart';

class _FilePane extends StatelessWidget {
  final AppStrings strings;
  final SftpViewModel sftp;

  const _FilePane({
    required this.strings,
    required this.sftp,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = context.select<SftpViewModel, _SftpPaneStatusSnapshot>(
      _SftpPaneStatusSnapshot.from,
    );
    final colorScheme = Theme.of(context).colorScheme;

    if (snapshot.state == SftpConnectionState.disconnected) {
      return _SftpEmptyState(strings: strings);
    }

    final desktop = isDesktopLayout(context);

    final topBar = Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: desktop
          ? Row(
              children: [
                IconButton(
                  tooltip: strings.parentDirectory,
                  icon: const Icon(Icons.arrow_upward_rounded),
                  onPressed: snapshot.isBusy ? null : sftp.openParent,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 40,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: OverflowScrollText(
                      snapshot.currentPath,
                      selectable: false,
                      maxLines: 1,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _SftpPathMenuButton(
                  strings: strings,
                  sftp: sftp,
                  currentPath: snapshot.currentPath,
                  disabled: snapshot.isBusy,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: strings.refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: snapshot.isBusy ? null : sftp.refresh,
                ),
                IconButton(
                  tooltip: strings.uploadFile,
                  icon: const Icon(Icons.upload_file_rounded),
                  onPressed:
                      snapshot.isBusy ? null : () => _uploadFile(context),
                ),
                IconButton(
                  tooltip: strings.disconnect,
                  icon: const Icon(Icons.link_off_rounded),
                  onPressed: sftp.disconnect,
                ),
              ],
            )
          : Row(
              children: [
                IconButton(
                  tooltip: strings.parentDirectory,
                  icon: const Icon(Icons.arrow_upward_rounded),
                  onPressed: snapshot.isBusy ? null : sftp.openParent,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: InkWell(
                    onTap: snapshot.isBusy
                        ? null
                        : () => _showPathHistorySheet(
                            context, sftp, snapshot.currentPath),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    child: Container(
                      height: 36,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.42),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusSmall),
                        border: Border.all(color: colorScheme.outlineVariant),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: OverflowScrollText(
                              snapshot.currentPath,
                              selectable: false,
                              maxLines: 1,
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Icon(Icons.edit,
                              size: 14, color: colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _SftpPathMenuButton(
                  strings: strings,
                  sftp: sftp,
                  currentPath: snapshot.currentPath,
                  disabled: snapshot.isBusy,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: strings.refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: snapshot.isBusy ? null : sftp.refresh,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: strings.uploadFile,
                  icon: const Icon(Icons.upload_file_rounded),
                  onPressed:
                      snapshot.isBusy ? null : () => _uploadFile(context),
                ),
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (value) {
                    if (value == 'disconnect') {
                      sftp.disconnect();
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'disconnect',
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              color: colorScheme.error),
                          const SizedBox(width: 8),
                          Text(
                            strings.disconnect,
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );

    return Column(
      children: [
        topBar,
        if (snapshot.isBusy && snapshot.activeTransfer == null)
          const LinearProgressIndicator(minHeight: 2),
        if (snapshot.activeTransfer != null)
          _SftpTransferBanner(
            strings: strings,
            sftp: sftp,
            activeTransfer: snapshot.activeTransfer!,
          ),
        if (snapshot.state == SftpConnectionState.error &&
            snapshot.errorMessage != null)
          MaterialBanner(
            content: Text(snapshot.errorMessage!),
            leading: const Icon(Icons.warning_amber_rounded),
            actions: [
              TextButton(
                onPressed: sftp.refresh,
                child: Text(strings.retry),
              ),
            ],
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
              strings
                  .uploadFileTooLarge(_formatBytes(SftpService.maxUploadBytes)),
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
          content: Text(
            strings.uploadFailed(
              strings.uploadFileNoAccess,
            ),
          ),
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
          SnackBar(
            content: Text(strings.uploadCancelled),
          ),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(strings.uploadFailed(e))),
      );
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
                  _formatBytes(settings.sftpDownloadLimitBytes)),
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
      messenger.showSnackBar(
        SnackBar(content: Text(strings.downloadComplete)),
      );
    } catch (e) {
      if (!context.mounted) return;
      if (e is SftpTransferCancelledException) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(strings.downloadCancelled),
          ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.deleteComplete)),
      );
    }
  }

  Future<void> _editFile(BuildContext context, SftpEntry entry) async {
    final saved = await Navigator.push<bool>(
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
    if (saved == true && context.mounted) {
      await context.read<SftpViewModel>().refresh();
    }
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
      BuildContext context, SftpViewModel sftp, String currentPath) {
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

class _SftpPathMenuButton extends StatelessWidget {
  final AppStrings strings;
  final SftpViewModel sftp;
  final String currentPath;
  final bool disabled;

  const _SftpPathMenuButton({
    required this.strings,
    required this.sftp,
    required this.currentPath,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: strings.pathHistory,
      icon: const Icon(Icons.star_outline_rounded),
      onPressed: disabled
          ? null
          : () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (_) => _SftpPathHistorySheet(
                  strings: strings,
                  sftp: sftp,
                  currentPath: currentPath,
                ),
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
  late final TextEditingController _pathController =
      TextEditingController(text: widget.currentPath);

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<_SftpPathHistoryData> _load() async {
    final favorites = await widget.sftp.loadFavoritePaths();
    final recent = await widget.sftp.loadRecentPaths();
    final currentFavorite =
        await widget.sftp.findFavoritePath(widget.currentPath);
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
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: FutureBuilder<_SftpPathHistoryData>(
            future: _future,
            builder: (context, snapshot) {
              final data = snapshot.data;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.strings.pathHistory,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
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
                          onPressed: snapshot.connectionState ==
                                  ConnectionState.waiting
                              ? null
                              : () => _toggleFavorite(data?.currentFavorite),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _pathController,
                            decoration: InputDecoration(
                              hintText: widget.strings.inputPath,
                              border: const OutlineInputBorder(),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            onSubmitted: (val) {
                              if (val.trim().isNotEmpty) {
                                _openPath(val.trim());
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.arrow_forward_rounded),
                          onPressed: () {
                            final path = _pathController.text.trim();
                            if (path.isNotEmpty) {
                              _openPath(path);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
                        children: [
                          _SftpPathSectionHeader(
                            label: widget.strings.favoritePaths,
                          ),
                          if (data == null || data.favorites.isEmpty)
                            _EmptyPathRow(label: widget.strings.noFavoritePaths)
                          else
                            for (final favorite in data.favorites)
                              _PathListTile(
                                icon: Icons.star_rounded,
                                label: favorite.name,
                                path: favorite.path,
                                trailing: IconButton(
                                  tooltip: widget.strings.removeFavoritePath,
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: () => _removeFavorite(favorite.id),
                                ),
                                onTap: () => _openPath(favorite.path),
                              ),
                          const SizedBox(height: 8),
                          _SftpPathSectionHeader(
                            label: widget.strings.recentPaths,
                          ),
                          if (data == null || data.recent.isEmpty)
                            _EmptyPathRow(label: widget.strings.noRecentPaths)
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
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
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
    return ListTile(
      dense: true,
      enabled: false,
      title: Text(label),
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
    return ListTile(
      leading: Icon(icon),
      title: OverflowScrollText(
        label,
        selectable: false,
        maxLines: 1,
      ),
      subtitle: OverflowScrollText(
        path,
        selectable: false,
        maxLines: 1,
      ),
      trailing: trailing,
      onTap: onTap,
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
  ) onEntryAction;
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
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(child: Text(strings.emptyDirectory));
    }

    final colorScheme = Theme.of(context).colorScheme;
    return ListView.separated(
      scrollCacheExtent: const ScrollCacheExtent.pixels(900.0),
      padding: EdgeInsets.fromLTRB(8 * scale, 8 * scale, 8 * scale, 24 * scale),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return RepaintBoundary(
          key: ValueKey('${entry.connectionId}:${entry.path}'),
          child: Builder(
            builder: (innerContext) {
              return TactileFeedback(
                onTap: entry.isDirectory
                    ? () => sftp.openPath(entry.path)
                    : () => onEntryAction(innerContext, 'view', entry),
                onLongPress: () => _showContextMenu(innerContext, entry),
                child: ListTile(
                  dense: scale < 0.95,
                  minLeadingWidth: 26 * scale,
                  leading: Icon(
                    entry.isDirectory
                        ? Icons.folder_rounded
                        : entry.isLink
                            ? Icons.shortcut_rounded
                            : Icons.description_outlined,
                    color: entry.isDirectory
                        ? colorScheme.primary
                        : colorScheme.onSurface.withValues(alpha: 0.72),
                    size: 20 * scale,
                  ),
                  title: entries.length > 100
                      ? OverflowScrollText(
                          entry.name,
                          selectable: false,
                          maxLines: 1,
                        )
                      : Hero(
                          tag: 'sftp_file_${entry.path}',
                          child: Material(
                            type: MaterialType.transparency,
                            child: OverflowScrollText(
                              entry.name,
                              selectable: false,
                              maxLines: 1,
                            ),
                          ),
                        ),
                  subtitle: OverflowScrollText(
                    entryMeta(strings, entry),
                    selectable: false,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withValues(alpha: 0.58),
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.isDirectory)
                        const Icon(Icons.chevron_right_rounded),
                      PopupMenuButton<String>(
                        onSelected: (action) => onEntryAction(
                          innerContext,
                          action,
                          entry,
                        ),
                        itemBuilder: (_) =>
                            _buildMenuItems(innerContext, entry),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  List<PopupMenuEntry<String>> _buildMenuItems(
      BuildContext context, SftpEntry entry) {
    return [
      if (!entry.isDirectory)
        PopupMenuItem(
          value: 'view',
          child: Row(
            children: [
              const Icon(
                Icons.visibility_outlined,
                size: 18,
              ),
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
              const Icon(
                Icons.download_rounded,
                size: 18,
              ),
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
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
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

class _SftpEmptyState extends StatelessWidget {
  final AppStrings strings;

  const _SftpEmptyState({required this.strings});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Icon(
                Icons.folder_open_rounded,
                color: colorScheme.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              strings.sftpEmptyTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.sftpEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.64),
                height: 1.35,
              ),
            ),
          ],
        ),
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
    final colorScheme = Theme.of(context).colorScheme;
    final isUpload = activeTransfer.isUpload;
    final progress = activeTransfer.progress;
    final totalBytes = activeTransfer.totalBytes;
    final transferredBytes = activeTransfer.bytesTransferred;

    final title = isUpload
        ? strings.uploadingFile(activeTransfer.name)
        : strings.downloadingFile(activeTransfer.name);

    final percentText =
        totalBytes > 0 ? ' ${(progress * 100).toStringAsFixed(0)}%' : '';

    final sizeText =
        '${_formatBytes(transferredBytes)}${totalBytes > 0 ? ' / ${_formatBytes(totalBytes)}' : ''}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isUpload ? Icons.upload_file_rounded : Icons.downloading_rounded,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      percentText,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: totalBytes > 0 ? progress : null,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 4),
                Text(
                  sizeText,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: Icon(Icons.close_rounded, color: colorScheme.error),
            tooltip: strings.cancel,
            onPressed:
                activeTransfer.isCancelled ? null : sftp.cancelActiveTransfer,
          ),
        ],
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
