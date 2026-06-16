part of '../sftp_screen.dart';

class _FilePane extends StatelessWidget {
  final AppStrings strings;
  final SftpService sftp;

  const _FilePane({
    required this.strings,
    required this.sftp,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = context.select<SftpService, _SftpPaneStatusSnapshot>(
      _SftpPaneStatusSnapshot.from,
    );
    final colorScheme = Theme.of(context).colorScheme;

    if (snapshot.state == SftpConnectionState.disconnected) {
      return _SftpEmptyState(strings: strings);
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          child: Row(
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
                    borderRadius: BorderRadius.circular(8),
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
              IconButton(
                tooltip: strings.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: snapshot.isBusy ? null : sftp.refresh,
              ),
              IconButton(
                tooltip: strings.uploadFile,
                icon: const Icon(Icons.upload_file_rounded),
                onPressed: snapshot.isBusy ? null : () => _uploadFile(context),
              ),
              IconButton(
                tooltip: strings.disconnect,
                icon: const Icon(Icons.link_off_rounded),
                onPressed: sftp.disconnect,
              ),
            ],
          ),
        ),
        if (snapshot.isBusy) const LinearProgressIndicator(minHeight: 2),
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
    final sftp = context.read<SftpService>();
    final strings = AppStrings(context.read<AppSettings>().language);
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.size > SftpService.maxUploadBytes) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.uploadFailed(
              'File is larger than ${_formatBytes(SftpService.maxUploadBytes)}',
            ),
          ),
        ),
      );
      return;
    }
    final bytes = file.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(strings.uploadFailed('Unable to read file'))),
      );
      return;
    }
    final filename = file.name.isNotEmpty
        ? file.name
        : p.basename(file.path ?? 'upload.bin');
    try {
      await sftp.uploadBytes(filename: filename, bytes: bytes);
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.uploadComplete)));
    } catch (e) {
      if (!context.mounted) return;
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
    final sftp = context.read<SftpService>();
    final messenger = ScaffoldMessenger.of(context);

    try {
      final bytes = await sftp.downloadBytes(
        entry,
        maxBytes: settings.sftpDownloadLimitBytes,
        updateState: true,
      );
      if (!context.mounted) return;
      final savedPath = await FilePicker.saveFile(
        dialogTitle: strings.downloadFile,
        fileName: entry.name,
        bytes: bytes,
      );
      if (!context.mounted || savedPath == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.downloadComplete)),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.downloadFailed(e))),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, SftpEntry entry) async {
    final settings = context.read<AppSettings>();
    final strings = AppStrings(settings.language);
    final sftp = context.read<SftpService>();
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
                  settings.isEnglish
                      ? 'Type the exact name to confirm:'
                      : '请输入完整名称确认：',
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
                    labelText: settings.isEnglish ? 'Entry name' : '文件或目录名称',
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
                    errorText =
                        settings.isEnglish ? 'Name does not match.' : '名称不匹配。';
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
      await context.read<SftpService>().refresh();
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
}

class _SftpEntryList extends StatelessWidget {
  final AppStrings strings;
  final SftpService sftp;
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
    final snapshot = context.select<SftpService, _SftpEntriesSnapshot>(
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
      cacheExtent: 900,
      padding: EdgeInsets.fromLTRB(8 * scale, 8 * scale, 8 * scale, 24 * scale),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return RepaintBoundary(
          key: ValueKey('${entry.connectionId}:${entry.path}'),
          child: TactileFeedback(
            onTap: entry.isDirectory ? () => sftp.openPath(entry.path) : null,
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
                      context,
                      action,
                      entry,
                    ),
                    itemBuilder: (_) => [
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
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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
                borderRadius: BorderRadius.circular(8),
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
