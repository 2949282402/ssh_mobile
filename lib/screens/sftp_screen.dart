import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/storage_service.dart';
import '../utils/responsive.dart';
import 'sftp_editor_screen.dart';
import 'sftp_file_viewer_screen.dart';

class SftpScreen extends StatelessWidget {
  const SftpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(context.watch<AppSettings>().language);
    final storageReady = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (storage) => storage.connections,
    );
    final sftp = context.watch<SftpService>();
    final desktop = isDesktopLayout(context);

    if (!storageReady) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return desktop
        ? Row(
            children: [
              SizedBox(
                width: 320,
                child: _ServerPane(
                  connections: connections,
                  strings: strings,
                  sftp: sftp,
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: _FilePane(strings: strings, sftp: sftp)),
            ],
          )
        : Column(
            children: [
              _MobileServerStrip(
                connections: connections,
                strings: strings,
                sftp: sftp,
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: _FilePane(strings: strings, sftp: sftp)),
            ],
          );
  }
}

class _ServerPane extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final SftpService sftp;

  const _ServerPane({
    required this.connections,
    required this.strings,
    required this.sftp,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              strings.sftpServers,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (connections.isEmpty)
            _SftpEmptyState(strings: strings)
          else
            for (final connection in connections)
              _ServerTile(
                connection: connection,
                selected: sftp.connectionId == connection.id,
                busy: sftp.isConnectionBusy(connection.id),
                connected: sftp.isConnectionOpen(connection.id),
                onTap: () => sftp.connect(connection.id),
              ),
        ],
      ),
    );
  }
}

class _MobileServerStrip extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final SftpService sftp;

  const _MobileServerStrip({
    required this.connections,
    required this.strings,
    required this.sftp,
  });

  @override
  Widget build(BuildContext context) {
    final textScale =
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8).toDouble();
    final stripHeight = 88.0 + (textScale - 1.0) * 28.0;
    if (connections.isEmpty) {
      return SizedBox(
        height: stripHeight,
        child: Center(child: Text(strings.noConnections)),
      );
    }

    return SizedBox(
      height: stripHeight,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        scrollDirection: Axis.horizontal,
        itemCount: connections.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final connection = connections[index];
          return SizedBox(
            width: 230,
            child: _ServerTile(
              connection: connection,
              selected: sftp.connectionId == connection.id,
              busy: sftp.isConnectionBusy(connection.id),
              connected: sftp.isConnectionOpen(connection.id),
              compact: true,
              onTap: () => sftp.connect(connection.id),
            ),
          );
        },
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final ConnectionConfig connection;
  final bool selected;
  final bool busy;
  final bool connected;
  final bool compact;
  final VoidCallback onTap;

  const _ServerTile({
    required this.connection,
    required this.selected,
    required this.busy,
    required this.connected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = selected
        ? colorScheme.primary.withValues(alpha: 0.52)
        : colorScheme.outlineVariant;

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 0 : 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: busy ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.1)
                : colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        connected
                            ? Icons.folder_shared_rounded
                            : Icons.folder_open_rounded,
                        color: colorScheme.primary,
                        size: 22,
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connection.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${connection.username}@${connection.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurface.withValues(alpha: 0.62),
                        fontSize: 12,
                      ),
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

class _FilePane extends StatelessWidget {
  final AppStrings strings;
  final SftpService sftp;

  const _FilePane({
    required this.strings,
    required this.sftp,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final entries = sftp.entries;

    if (sftp.state == SftpConnectionState.disconnected) {
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
                onPressed: sftp.isBusy ? null : sftp.openParent,
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
                  child: Text(
                    sftp.currentPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: strings.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: sftp.isBusy ? null : sftp.refresh,
              ),
              IconButton(
                tooltip: strings.uploadFile,
                icon: const Icon(Icons.upload_file_rounded),
                onPressed: sftp.isBusy ? null : () => _uploadFile(context),
              ),
              IconButton(
                tooltip: strings.disconnect,
                icon: const Icon(Icons.link_off_rounded),
                onPressed: sftp.disconnect,
              ),
            ],
          ),
        ),
        if (sftp.isBusy) const LinearProgressIndicator(minHeight: 2),
        if (sftp.state == SftpConnectionState.error &&
            sftp.errorMessage != null)
          MaterialBanner(
            content: Text(sftp.errorMessage!),
            leading: const Icon(Icons.warning_amber_rounded),
            actions: [
              TextButton(
                onPressed: sftp.refresh,
                child: Text(strings.retry),
              ),
            ],
          ),
        Expanded(
          child: entries.isEmpty && !sftp.isBusy
              ? Center(child: Text(strings.emptyDirectory))
              : ListView.separated(
                  cacheExtent: 900,
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return RepaintBoundary(
                      key: ValueKey('${entry.connectionId}:${entry.path}'),
                      child: ListTile(
                        minLeadingWidth: 28,
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder_rounded
                              : entry.isLink
                                  ? Icons.shortcut_rounded
                                  : Icons.description_outlined,
                          color: entry.isDirectory
                              ? colorScheme.primary
                              : colorScheme.onSurface.withValues(alpha: 0.72),
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          _entryMeta(strings, entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (entry.isDirectory)
                              const Icon(Icons.chevron_right_rounded),
                            PopupMenuButton<String>(
                              onSelected: (action) =>
                                  _handleEntryAction(context, action, entry),
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
                                        const Icon(Icons.edit_outlined,
                                            size: 18),
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
                                      const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                        color: Colors.redAccent,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        strings.delete,
                                        style: const TextStyle(
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: entry.isDirectory
                            ? () => sftp.openPath(entry.path)
                            : null,
                      ),
                    );
                  },
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
    if (file.size > SftpService.maxInMemoryTransferBytes) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.uploadFailed(
              'File is larger than ${_formatBytes(SftpService.maxInMemoryTransferBytes)}',
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
      MaterialPageRoute(
        builder: (_) => SftpFileViewerScreen(entry: entry),
      ),
    );
  }

  Future<void> _downloadFile(BuildContext context, SftpEntry entry) async {
    final strings = AppStrings(context.read<AppSettings>().language);
    final sftp = context.read<SftpService>();
    final messenger = ScaffoldMessenger.of(context);

    try {
      final bytes = await sftp.downloadBytes(entry, updateState: true);
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
    final strings = AppStrings(context.read<AppSettings>().language);
    final sftp = context.read<SftpService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.deleteRemoteEntry),
        content: Text(strings.deleteRemoteEntryContent(entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await sftp.deleteEntry(entry);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.deleteComplete)),
      );
    }
  }

  Future<void> _editFile(BuildContext context, SftpEntry entry) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SftpEditorScreen(entry: entry),
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
