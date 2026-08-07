part of 'sftp_screen.dart';

class _ServerPane extends StatelessWidget {
  final List<ConnectionConfig> connections;
  final AppStrings strings;
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
      subtitle: strings.language == AppLanguage.en
          ? '${connections.length} available'
          : '共 ${connections.length} 台可用',
      headerIcon: Icons.folder_shared_rounded,
      collapseTooltip: strings.collapseServerList,
      reorderTooltip: strings.reorderServer,
      collapseButtonKey: const ValueKey('sftp-server-collapse-desktop'),
      dragHandleKeyBuilder: (connection) =>
          ValueKey('sftp-server-drag-${connection.id}'),
      onCollapse: onCollapse,
      onReorder: (oldIndex, newIndex) {
        context.read<ConnectionViewModel>().reorderConnections(
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
  final List<ConnectionConfig> connections;
  final AppStrings strings;
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
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 2.0).toDouble();
    final status = _SftpServerStatus.of(
      context,
      strings: strings,
      busy: busy,
      connected: connected,
    );
    final barHeight = 48.0 + (textScale - 1.0) * 22.0;
    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: barHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    key: const ValueKey('sftp-server-expand-mobile'),
                    tooltip: strings.expandServerList,
                    icon: const Icon(Icons.keyboard_double_arrow_down_rounded),
                    onPressed: onExpand,
                  ),
                ),
                const SizedBox(width: 8),
                _ServerStatusIcon(
                  busy: busy,
                  connected: connected,
                  compact: true,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    key: const ValueKey('sftp-collapsed-server-summary'),
                    container: true,
                    label: connection == null
                        ? strings.sftpServers
                        : '${connection.name}, ${status.label}, '
                              '${connection.username}@${connection.host}:${connection.port}',
                    child: ExcludeSemantics(
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
              child: CircularProgressIndicator(
                key: const ValueKey('sftp-server-status-loading'),
                color: color,
                strokeWidth: 1.8 * scale,
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
  final ConnectionConfig connection;
  final AppStrings strings;
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
    final theme = Theme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final scale = mobileUiScaleOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final stackStatus = !compact && textScale >= 1.5;
    final isDark = theme.brightness == Brightness.dark;
    final status = _SftpServerStatus.of(
      context,
      strings: strings,
      busy: busy,
      connected: connected,
    );
    final borderColor = selected
        ? colorScheme.primary.withValues(alpha: 0.58)
        : compact
        ? colorScheme.outlineVariant
        : colorScheme.outline.withValues(alpha: 0.62);
    final background = compact
        ? (selected
              ? colorScheme.primary.withValues(alpha: 0.08)
              : colorScheme.surface)
        : selected
        ? Color.alphaBlend(
            colorScheme.primary.withValues(alpha: isDark ? 0.12 : 0.075),
            colorScheme.surfaceContainerLow,
          )
        : colorScheme.surfaceContainerLow.withValues(alpha: 0.76);
    final title = OverflowScrollText(
      connection.name,
      selectable: false,
      maxLines: 1,
      style: TextStyle(
        color: colorScheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    );
    final endpoint = Row(
      children: [
        Icon(
          Icons.dns_outlined,
          size: 13 * scale,
          color: colorScheme.onSurfaceVariant,
        ),
        SizedBox(width: 5 * scale),
        Expanded(
          child: OverflowScrollText(
            '${connection.username}@${connection.host}:${connection.port}',
            selectable: false,
            maxLines: 1,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
      ],
    );

    return Semantics(
      key: ValueKey('sftp-server-tile-${connection.id}'),
      container: true,
      button: true,
      enabled: !busy,
      selected: selected,
      label:
          '${connection.name}, ${status.label}, '
          '${connection.username}@${connection.host}:${connection.port}',
      onTap: busy ? null : onTap,
      child: TactileFeedback(
        onTap: busy ? null : onTap,
        child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            constraints: BoxConstraints(
              minHeight: compact
                  ? 56
                  : stackStatus
                  ? 112
                  : 72,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: (compact ? 10 : 14) * scale,
              vertical: (compact ? 3 : 11) * scale,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(
                compact ? AppTheme.radiusSmall : AppTheme.radiusMedium,
              ),
              border: Border.all(color: borderColor, width: selected ? 1.2 : 1),
              boxShadow: compact
                  ? const []
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: selected
                              ? (isDark ? 0.20 : 0.055)
                              : (isDark ? 0.12 : 0.025),
                        ),
                        blurRadius: selected ? 16 : 10,
                        offset: Offset(0, selected ? 6 : 3),
                      ),
                    ],
            ),
            child: Row(
              children: [
                _ServerStatusIcon(
                  busy: busy,
                  connected: connected,
                  compact: true,
                ),
                SizedBox(width: 10 * scale),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (compact) ...[
                        title,
                        SizedBox(height: 3 * scale),
                        endpoint,
                      ] else if (stackStatus) ...[
                        title,
                        SizedBox(height: 2 * scale),
                        Text(
                          status.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: status.color,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 3 * scale),
                        endpoint,
                      ] else ...[
                        Row(
                          children: [
                            Expanded(child: title),
                            SizedBox(width: 8 * scale),
                            _SftpServerStatusPill(status: status),
                          ],
                        ),
                        SizedBox(height: 5 * scale),
                        endpoint,
                      ],
                    ],
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

class _SftpServerStatus {
  const _SftpServerStatus({required this.label, required this.color});

  final String label;
  final Color color;

  factory _SftpServerStatus.of(
    BuildContext context, {
    required AppStrings strings,
    required bool busy,
    required bool connected,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final extended = theme.extension<ExtendedColors>();
    if (busy) {
      return _SftpServerStatus(
        label: strings.connecting,
        color: extended?.warning ?? colors.primary,
      );
    }
    if (connected) {
      return _SftpServerStatus(
        label: strings.connected,
        color: extended?.success ?? colors.secondary,
      );
    }
    return _SftpServerStatus(
      label: strings.disconnected,
      color: colors.onSurfaceVariant,
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
  final ConnectionConfig connection;
  final AppStrings strings;
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
