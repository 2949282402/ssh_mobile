part of 'sftp_screen.dart';

class _ServerPane extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final VoidCallback onCollapse;

  const _ServerPane({
    required this.connections,
    required this.strings,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (connections.isEmpty) {
      return Material(
        color: colorScheme.surface,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _header(context, colorScheme),
            _SftpEmptyState(strings: strings),
          ],
        ),
      );
    }
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          _header(context, colorScheme),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              itemCount: connections.length,
              itemBuilder: (context, index) {
                final connection = connections[index];
                return Container(
                  key: ValueKey(connection.id),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.drag_handle,
                            size: 20,
                            color: colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                      Expanded(
                        child: _SftpServerTileBinding(
                          connection: connection,
                        ),
                      ),
                    ],
                  ),
                );
              },
              onReorder: (oldIndex, newIndex) {
                final storageNewIndex =
                    newIndex > oldIndex ? newIndex + 1 : newIndex;
                context
                    .read<ConnectionViewModel>()
                    .reorderConnections(oldIndex, storageNewIndex);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
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
    );
  }
}

class _MobileServerStrip extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
  final VoidCallback onCollapse;

  const _MobileServerStrip({
    super.key,
    required this.connections,
    required this.strings,
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
            child: _SftpServerTileBinding(
              connection: connection,
              compact: true,
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
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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
                  child: OverflowScrollText(
                    connection == null
                        ? strings.sftpServers
                        : '${connection.name}  ${connection.username}@${connection.host}',
                    selectable: false,
                    maxLines: 1,
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
    final scale = mobileUiScaleOf(context);
    final size = (compact ? 30.0 : 38.0) * scale;
    final iconSize = (compact ? 18.0 : 22.0) * scale;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.16)
            : colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: selected
            ? Border.all(color: colorScheme.primary.withValues(alpha: 0.42))
            : null,
      ),
      child: busy
          ? Padding(
              padding: EdgeInsets.all(compact ? 7 * scale : 10 * scale),
              child: CircularProgressIndicator(strokeWidth: 2 * scale),
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
    final scale = mobileUiScaleOf(context);
    final borderColor = selected
        ? colorScheme.primary.withValues(alpha: 0.54)
        : colorScheme.outlineVariant;

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 0 : 8 * scale),
      child: TactileFeedback(
        onTap: busy ? null : onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10 * scale,
            vertical: 8 * scale,
          ),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.12)
                : colorScheme.surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 30 * scale,
                height: 30 * scale,
                alignment: Alignment.center,
                child: _ServerStatusIcon(
                  busy: busy,
                  connected: connected,
                  selected: selected,
                  compact: true,
                ),
              ),
              SizedBox(width: 8 * scale),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OverflowScrollText(
                      connection.name,
                      selectable: false,
                      maxLines: 1,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3 * scale),
                    OverflowScrollText(
                      '${connection.username}@${connection.host}',
                      selectable: false,
                      maxLines: 1,
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

class _SftpServerTileBinding extends StatelessWidget {
  final ConnectionConfig connection;
  final bool compact;

  const _SftpServerTileBinding({
    required this.connection,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<SftpViewModel, _SftpConnectionStatusSnapshot>(
      selector: (_, service) =>
          _SftpConnectionStatusSnapshot.from(service, connection.id),
      builder: (context, status, _) => _ServerTile(
        connection: connection,
        selected: status.selected,
        busy: status.busy,
        connected: status.connected,
        compact: compact,
        onTap: () => context.read<SftpViewModel>().connect(
              connection.id,
              onUnknownHostKey: (request) =>
                  showSshHostKeyTrustDialog(context, request),
            ),
      ),
    );
  }
}
