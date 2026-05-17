import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/storage_service.dart';
import '../utils/responsive.dart';
import 'sftp_editor_screen.dart';
import 'sftp_file_viewer_screen.dart';

class SftpScreen extends StatefulWidget {
  const SftpScreen({super.key});

  @override
  State<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends State<SftpScreen> {
  static const _serversCollapsedStorageKey = 'sftp_servers_collapsed';

  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredServersCollapsed) return;
    _restoredServersCollapsed = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: _serversCollapsedStorageKey,
    );
    if (stored is bool) _serversCollapsed = stored;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(context.watch<AppSettings>().language);
    final storageReady = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (storage) => storage.connections,
    );
    final sftp = context.read<SftpService>();
    final snapshot = context.select<SftpService, _SftpUiSnapshot>(
      (service) => _SftpUiSnapshot.from(service, connections),
    );
    final desktop = isDesktopLayout(context);
    final selectedConnection = _selectedConnection(connections, snapshot);
    final serversCollapsed = _serversCollapsed && connections.isNotEmpty;

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
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: serversCollapsed ? 64 : 320,
                child: serversCollapsed
                    ? _CollapsedDesktopServerRail(
                        selectedConnection: selectedConnection,
                        busy: selectedConnection != null &&
                            snapshot.isConnectionBusy(selectedConnection.id),
                        connected: selectedConnection != null &&
                            snapshot.isConnectionOpen(selectedConnection.id),
                        strings: strings,
                        onExpand: _expandServers,
                      )
                    : _ServerPane(
                        connections: connections,
                        strings: strings,
                        sftp: sftp,
                        snapshot: snapshot,
                        onCollapse: _collapseServers,
                      ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(
                child: _FilePane(
                  strings: strings,
                  sftp: sftp,
                  snapshot: snapshot,
                ),
              ),
            ],
          )
        : Column(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: serversCollapsed
                    ? _CollapsedMobileServerBar(
                        key: const ValueKey('sftp-server-collapsed'),
                        selectedConnection: selectedConnection,
                        busy: selectedConnection != null &&
                            snapshot.isConnectionBusy(selectedConnection.id),
                        connected: selectedConnection != null &&
                            snapshot.isConnectionOpen(selectedConnection.id),
                        strings: strings,
                        onExpand: _expandServers,
                      )
                    : _MobileServerStrip(
                        key: const ValueKey('sftp-server-expanded'),
                        connections: connections,
                        strings: strings,
                        sftp: sftp,
                        snapshot: snapshot,
                        onCollapse: _collapseServers,
                      ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(
                child: _FilePane(
                  strings: strings,
                  sftp: sftp,
                  snapshot: snapshot,
                ),
              ),
            ],
          );
  }

  void _collapseServers() {
    _setServersCollapsed(true);
  }

  void _expandServers() {
    _setServersCollapsed(false);
  }

  void _setServersCollapsed(bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    setState(() => _serversCollapsed = collapsed);
    PageStorage.maybeOf(context)?.writeState(
      context,
      collapsed,
      identifier: _serversCollapsedStorageKey,
    );
  }

  ConnectionConfig? _selectedConnection(
    List<ConnectionConfig> connections,
    _SftpUiSnapshot snapshot,
  ) {
    final activeId = snapshot.connectionId;
    if (activeId == null) return null;
    for (final connection in connections) {
      if (connection.id == activeId) return connection;
    }
    return null;
  }
}

class _ServerPane extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final SftpService sftp;
  final _SftpUiSnapshot snapshot;
  final VoidCallback onCollapse;

  const _ServerPane({
    required this.connections,
    required this.strings,
    required this.sftp,
    required this.snapshot,
    required this.onCollapse,
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
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings.sftpServers,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: strings.collapseServerList,
                  icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
                  onPressed: connections.isEmpty ? null : onCollapse,
                ),
              ],
            ),
          ),
          if (connections.isEmpty)
            _SftpEmptyState(strings: strings)
          else
            for (final connection in connections)
              _ServerTile(
                connection: connection,
                selected: snapshot.connectionId == connection.id,
                busy: snapshot.isConnectionBusy(connection.id),
                connected: snapshot.isConnectionOpen(connection.id),
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
  final _SftpUiSnapshot snapshot;
  final VoidCallback onCollapse;

  const _MobileServerStrip({
    super.key,
    required this.connections,
    required this.strings,
    required this.sftp,
    required this.snapshot,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final textScale =
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8).toDouble();
    final stripHeight = 72.0 + (textScale - 1.0) * 18.0;
    if (connections.isEmpty) {
      return SizedBox(
        height: stripHeight,
        child: Center(child: Text(strings.noConnections)),
      );
    }

    return SizedBox(
      height: stripHeight,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: connections.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _MobileCollapseButton(
              strings: strings,
              onPressed: onCollapse,
            );
          }
          final connection = connections[index - 1];
          return SizedBox(
            width: 210,
            child: _ServerTile(
              connection: connection,
              selected: snapshot.connectionId == connection.id,
              busy: snapshot.isConnectionBusy(connection.id),
              connected: snapshot.isConnectionOpen(connection.id),
              compact: true,
              onTap: () => sftp.connect(connection.id),
            ),
          );
        },
      ),
    );
  }
}

class _MobileCollapseButton extends StatelessWidget {
  final AppStrings strings;
  final VoidCallback onPressed;

  const _MobileCollapseButton({
    required this.strings,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 48,
      child: Material(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: strings.collapseServerList,
          icon: const Icon(Icons.keyboard_double_arrow_up_rounded),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class _CollapsedMobileServerBar extends StatelessWidget {
  final ConnectionConfig? selectedConnection;
  final bool busy;
  final bool connected;
  final AppStrings strings;
  final VoidCallback onExpand;

  const _CollapsedMobileServerBar({
    super.key,
    required this.selectedConnection,
    required this.busy,
    required this.connected,
    required this.strings,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connection = selectedConnection;
    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: strings.expandServerList,
                  icon: const Icon(Icons.keyboard_double_arrow_down_rounded),
                  onPressed: onExpand,
                ),
                _ServerStatusIcon(
                  busy: busy,
                  connected: connected,
                  compact: true,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    connection == null
                        ? strings.sftpServers
                        : '${connection.name}  ${connection.username}@${connection.host}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedDesktopServerRail extends StatelessWidget {
  final ConnectionConfig? selectedConnection;
  final bool busy;
  final bool connected;
  final AppStrings strings;
  final VoidCallback onExpand;

  const _CollapsedDesktopServerRail({
    required this.selectedConnection,
    required this.busy,
    required this.connected,
    required this.strings,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 8),
          IconButton(
            tooltip: strings.expandServerList,
            icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
            onPressed: onExpand,
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: selectedConnection == null
                ? strings.sftpServers
                : '${selectedConnection!.name}\n${selectedConnection!.username}@${selectedConnection!.host}',
            child: _ServerStatusIcon(
              busy: busy,
              connected: connected,
              selected: selectedConnection != null,
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerStatusIcon extends StatelessWidget {
  final bool busy;
  final bool connected;
  final bool selected;
  final bool compact;

  const _ServerStatusIcon({
    required this.busy,
    required this.connected,
    this.selected = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = compact ? 30.0 : 38.0;
    final iconSize = compact ? 18.0 : 22.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.16)
            : colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: selected
            ? Border.all(color: colorScheme.primary.withValues(alpha: 0.42))
            : null,
      ),
      child: busy
          ? Padding(
              padding: EdgeInsets.all(compact ? 7 : 10),
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              connected
                  ? Icons.folder_shared_rounded
                  : Icons.folder_open_rounded,
              color: colorScheme.primary,
              size: iconSize,
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                width: 30,
                height: 30,
                alignment: Alignment.center,
                child: _ServerStatusIcon(
                  busy: busy,
                  connected: connected,
                  selected: selected,
                ),
              ),
              const SizedBox(width: 8),
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
  final _SftpUiSnapshot snapshot;

  const _FilePane({
    required this.strings,
    required this.sftp,
    required this.snapshot,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final entries = snapshot.entries;

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
                  child: Text(
                    snapshot.currentPath,
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
          child: snapshot.isBusy
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : entries.isEmpty
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
                                  : colorScheme.onSurface
                                      .withValues(alpha: 0.72),
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
                                  onSelected: (action) => _handleEntryAction(
                                      context, action, entry),
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
      MaterialPageRoute(
        builder: (_) => SftpFileViewerScreen(entry: entry),
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
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
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

class _SftpUiSnapshot {
  final String? connectionId;
  final String currentPath;
  final SftpConnectionState state;
  final String? errorMessage;
  final List<SftpEntry> entries;
  final Set<String> busyConnectionIds;
  final Set<String> openConnectionIds;

  const _SftpUiSnapshot({
    required this.connectionId,
    required this.currentPath,
    required this.state,
    required this.errorMessage,
    required this.entries,
    required this.busyConnectionIds,
    required this.openConnectionIds,
  });

  factory _SftpUiSnapshot.from(
    SftpService service,
    List<ConnectionConfig> connections,
  ) {
    return _SftpUiSnapshot(
      connectionId: service.connectionId,
      currentPath: service.currentPath,
      state: service.state,
      errorMessage: service.errorMessage,
      entries: service.entries,
      busyConnectionIds: {
        for (final connection in connections)
          if (service.isConnectionBusy(connection.id)) connection.id,
      },
      openConnectionIds: {
        for (final connection in connections)
          if (service.isConnectionOpen(connection.id)) connection.id,
      },
    );
  }

  bool get isBusy =>
      state == SftpConnectionState.connecting ||
      state == SftpConnectionState.loading;

  bool isConnectionBusy(String connectionId) {
    return busyConnectionIds.contains(connectionId);
  }

  bool isConnectionOpen(String connectionId) {
    return openConnectionIds.contains(connectionId);
  }

  @override
  bool operator ==(Object other) {
    return other is _SftpUiSnapshot &&
        other.connectionId == connectionId &&
        other.currentPath == currentPath &&
        other.state == state &&
        other.errorMessage == errorMessage &&
        listEquals(other.entries, entries) &&
        setEquals(other.busyConnectionIds, busyConnectionIds) &&
        setEquals(other.openConnectionIds, openConnectionIds);
  }

  @override
  int get hashCode => Object.hash(
        connectionId,
        currentPath,
        state,
        errorMessage,
        Object.hashAll(entries),
        Object.hashAllUnordered(busyConnectionIds),
        Object.hashAllUnordered(openConnectionIds),
      );
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
