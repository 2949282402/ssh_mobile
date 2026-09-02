part of 'sftp_screen.dart';

class _ServerPane extends StatelessWidget {
  final List<SftpConnectionInfo> connections;
  final SftpStrings strings;
  final VoidCallback onCollapse;
  final Future<void> Function(String connectionId) onSelect;

  const _ServerPane({
    required this.connections,
    required this.strings,
    required this.onCollapse,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ServerSelectorPane(
      key: const ValueKey('sftp-server-pane'),
      connections: connections,
      title: strings.sftpServers,
      subtitle: strings.language == SftpLanguage.english
          ? '${connections.length} available'
          : '共 ${connections.length} 台可用',
      headerIcon: Icons.folder_shared_rounded,
      collapseTooltip: strings.collapseServerList,
      reorderTooltip: strings.reorderServer,
      itemKeyBuilder: (connection) => ValueKey('sftp-server-${connection.id}'),
      collapseButtonKey: const ValueKey('sftp-server-collapse-desktop'),
      dragHandleKeyBuilder: (connection) =>
          ValueKey('sftp-server-drag-${connection.id}'),
      onCollapse: onCollapse,
      onReorder: (oldIndex, newIndex) {
        context.read<SftpConnectionCatalogPort>().reorderConnections(
          oldIndex,
          newIndex,
        );
      },
      tileBuilder: (context, connection, compact) => _SftpServerTileBinding(
        connection: connection,
        strings: strings,
        compact: compact,
        onTap: () => onSelect(connection.id),
      ),
      emptyState: AppEmptyState(
        icon: Icons.dns_outlined,
        title: strings.noConnections,
        message: strings.sftpEmptyHint,
        compact: true,
        contained: false,
      ),
    );
  }
}

class _MobileServerStrip extends StatelessWidget {
  final List<SftpConnectionInfo> connections;
  final SftpStrings strings;
  final VoidCallback onCollapse;
  final Future<void> Function(String connectionId) onSelect;

  const _MobileServerStrip({
    super.key,
    required this.connections,
    required this.strings,
    required this.onCollapse,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ServerSelectorStrip(
      key: const ValueKey('sftp-mobile-server-strip'),
      connections: connections,
      semanticsLabel: strings.sftpServers,
      noConnectionsLabel: strings.noConnections,
      collapseTooltip: strings.collapseServerList,
      collapseButtonKey: const ValueKey('sftp-server-collapse-mobile'),
      onCollapse: onCollapse,
      tileBuilder: (context, connection, compact) => _SftpServerTileBinding(
        connection: connection,
        strings: strings,
        compact: compact,
        onTap: () => onSelect(connection.id),
      ),
    );
  }
}

class _CollapsedMobileServerBar extends StatelessWidget {
  final SftpConnectionInfo? selectedConnection;
  final bool busy;
  final bool connected;
  final SftpStrings strings;
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
    final connection = selectedConnection;
    final status = _SftpServerStatus.of(
      context,
      strings: strings,
      busy: busy,
      connected: connected,
    );
    return AppServerSummaryBar(
      title: connection == null ? strings.sftpServers : connection.name,
      subtitle: connection == null
          ? null
          : '${connection.username}@${connection.host}',
      statusIcon: _ServerStatusIcon(
        busy: busy,
        connected: connected,
        compact: true,
      ),
      expandTooltip: strings.expandServerList,
      expandButtonKey: const ValueKey('sftp-server-expand-mobile'),
      onExpand: onExpand,
      semanticsKey: const ValueKey('sftp-collapsed-server-summary'),
      semanticsLabel: connection == null
          ? strings.sftpServers
          : '${connection.name}, ${status.label}, '
                '${connection.username}@${connection.host}:${connection.port}',
    );
  }
}

class _CollapsedDesktopServerRail extends StatelessWidget {
  final SftpConnectionInfo? selectedConnection;
  final bool busy;
  final bool connected;
  final SftpStrings strings;
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
    final status = _SftpServerStatus.of(
      context,
      strings: strings,
      busy: busy,
      connected: connected,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.88),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          SizedBox.square(
            dimension: 48,
            child: IconButton.filledTonal(
              key: const ValueKey('sftp-server-expand-desktop'),
              tooltip: strings.expandServerList,
              icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
              onPressed: onExpand,
            ),
          ),
          const SizedBox(height: 14),
          Semantics(
            label: selectedConnection == null
                ? strings.sftpServers
                : '${selectedConnection!.name}, ${status.label}, '
                      '${selectedConnection!.username}@${selectedConnection!.host}:${selectedConnection!.port}',
            child: ExcludeSemantics(
              child: Tooltip(
                message: selectedConnection == null
                    ? strings.sftpServers
                    : '${selectedConnection!.name}\n${status.label}\n'
                          '${selectedConnection!.username}@${selectedConnection!.host}:${selectedConnection!.port}',
                child: _ServerStatusIcon(busy: busy, connected: connected),
              ),
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
  final bool compact;

  const _ServerStatusIcon({
    required this.busy,
    required this.connected,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final extended = Theme.of(context).extension<ExtendedColors>();
    final scale = mobileUiScaleOf(context);
    final size = (compact ? 30.0 : 38.0) * scale;
    final iconSize = (compact ? 18.0 : 22.0) * scale;
    final color = busy
        ? extended?.warning ?? colorScheme.primary
        : connected
        ? extended?.success ?? colorScheme.secondary
        : colorScheme.onSurfaceVariant;

    return SizedBox.square(
      dimension: size,
      child: busy
          ? Padding(
              padding: EdgeInsets.all(4 * scale),
              child: AppLoadingIndicator(
                key: const ValueKey('sftp-server-status-loading'),
                color: color,
                strokeWidth: 1.8 * scale,
                size: size - 8 * scale,
              ),
            )
          : AppIconBadge(
              key: const ValueKey('sftp-server-status-icon'),
              icon: connected
                  ? Icons.folder_shared_rounded
                  : Icons.folder_open_rounded,
              size: size,
              iconSize: iconSize,
              color: color,
            ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final SftpConnectionInfo connection;
  final SftpStrings strings;
  final bool selected;
  final bool busy;
  final bool connected;
  final bool compact;
  final VoidCallback onTap;

  const _ServerTile({
    required this.connection,
    required this.strings,
    required this.selected,
    required this.busy,
    required this.connected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final status = _SftpServerStatus.of(
      context,
      strings: strings,
      busy: busy,
      connected: connected,
    );

    return AppServerTile(
      title: connection.name,
      subtitle: '${connection.username}@${connection.host}:${connection.port}',
      leading: _ServerStatusIcon(
        busy: busy,
        connected: connected,
        compact: true,
      ),
      trailing: _SftpServerStatusPill(status: status),
      statusWidget: Text(
        status.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: status.color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      selected: selected,
      busy: busy,
      compact: compact,
      onTap: onTap,
      semanticsKey: ValueKey('sftp-server-tile-${connection.id}'),
      semanticsLabel:
          '${connection.name}, ${status.label}, '
          '${connection.username}@${connection.host}:${connection.port}',
    );
  }
}

class _SftpServerStatus {
  const _SftpServerStatus({required this.label, required this.color});

  final String label;
  final Color color;

  factory _SftpServerStatus.of(
    BuildContext context, {
    required SftpStrings strings,
    required bool busy,
    required bool connected,
  }) {
    final status = AppStatusColors.of(context);
    if (busy) {
      return _SftpServerStatus(
        label: strings.connecting,
        color: status.warning,
      );
    }
    if (connected) {
      return _SftpServerStatus(label: strings.connected, color: status.success);
    }
    return _SftpServerStatus(
      label: strings.disconnected,
      color: status.neutral,
    );
  }
}

class _SftpServerStatusPill extends StatelessWidget {
  const _SftpServerStatusPill({required this.status});

  final _SftpServerStatus status;

  @override
  Widget build(BuildContext context) {
    final scale = mobileUiScaleOf(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        border: Border.all(color: status.color.withValues(alpha: 0.34)),
      ),
      child: Text(
        status.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: status.color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SftpServerTileBinding extends StatelessWidget {
  final SftpConnectionInfo connection;
  final SftpStrings strings;
  final bool compact;
  final VoidCallback onTap;

  const _SftpServerTileBinding({
    required this.connection,
    required this.strings,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<SftpViewModel, _SftpConnectionStatusSnapshot>(
      selector: (_, service) =>
          _SftpConnectionStatusSnapshot.from(service, connection.id),
      builder: (context, status, _) => _ServerTile(
        connection: connection,
        strings: strings,
        selected: status.selected,
        busy: status.busy,
        connected: status.connected,
        compact: compact,
        onTap: onTap,
      ),
    );
  }
}
