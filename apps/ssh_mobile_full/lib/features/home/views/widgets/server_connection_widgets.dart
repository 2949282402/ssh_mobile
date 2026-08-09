part of '../home_screen.dart';

// --- Top-Level Library-Private Formatting & Color Helpers ---

Color _panelColor(BuildContext context) {
  return Theme.of(context).colorScheme.surface;
}

Color _panelBorderColor(BuildContext context) {
  return Theme.of(context).colorScheme.outlineVariant;
}

Color _panelTextColor(BuildContext context) {
  return Theme.of(context).colorScheme.onSurface;
}

Color _panelMutedTextColor(BuildContext context) {
  return Theme.of(context).colorScheme.onSurfaceVariant;
}

IconData _getStatusIcon(ConnectionConfig conn, SshConnectionState? state) {
  if (state != null) {
    if (state == SshConnectionState.connected) return Icons.link;
    if (state == SshConnectionState.connecting) return Icons.sync;
    return Icons.link_off;
  }
  return Icons.dns_outlined;
}

Color _healthColor(BuildContext context, ServerHealthLevel level) {
  final colorScheme = Theme.of(context).colorScheme;
  return switch (level) {
    ServerHealthLevel.healthy => colorScheme.secondary,
    ServerHealthLevel.warning => Colors.orangeAccent.shade700,
    ServerHealthLevel.critical => colorScheme.error,
    ServerHealthLevel.unknown => colorScheme.onSurfaceVariant,
  };
}

IconData _healthIcon(ServerHealthLevel level) {
  return switch (level) {
    ServerHealthLevel.healthy => Icons.verified_rounded,
    ServerHealthLevel.warning => Icons.warning_amber_rounded,
    ServerHealthLevel.critical => Icons.error_rounded,
    ServerHealthLevel.unknown => Icons.help_outline_rounded,
  };
}

String _healthLabel(AppStrings strings, ServerHealthLevel level) {
  final en = strings.language == AppLanguage.en;
  return switch (level) {
    ServerHealthLevel.healthy => en ? 'Healthy' : '正常',
    ServerHealthLevel.warning => en ? 'Warning' : '警告',
    ServerHealthLevel.critical => en ? 'Critical' : '危险',
    ServerHealthLevel.unknown => strings.noMonitoringData,
  };
}

// --- Extracted Sub-widgets ---

class _ServerEmptyState extends StatelessWidget {
  final AppStrings strings;

  const _ServerEmptyState({required this.strings});

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.terminal_rounded,
      title: strings.noConnections,
      message: strings.addHint,
      action: FilledButton.icon(
        onPressed: () => Navigator.pushNamed(
          context,
          '/add',
          arguments: context.read<ConnectionViewModel>(),
        ),
        icon: const Icon(Icons.add_rounded),
        label: Text(strings.addConnection),
      ),
    );
  }
}

class _ServerSkeletalLoader extends StatelessWidget {
  const _ServerSkeletalLoader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark
        ? const Color(0xFF1E293B)
        : const Color(0xFFE2E8F0);
    final highlightColor = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFF1F5F9);

    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: 3,
      itemBuilder: (context, index) {
        return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: baseColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFCBD5E1),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: highlightColor,
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusSmall,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 140,
                        height: 18,
                        decoration: BoxDecoration(
                          color: highlightColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: 220,
                    height: 12,
                    decoration: BoxDecoration(
                      color: highlightColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 100,
                    height: 12,
                    decoration: BoxDecoration(
                      color: highlightColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            )
            .animate(onPlay: (controller) => controller.repeat())
            .shimmer(
              duration: const Duration(milliseconds: 1200),
              color: highlightColor.withValues(alpha: 0.35),
            );
      },
    );
  }
}

class _ServerSelectionBar extends StatelessWidget {
  final AppStrings strings;
  final Set<String> selectedServerIds;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  const _ServerSelectionBar({
    required this.strings,
    required this.selectedServerIds,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final count = selectedServerIds.length;
    return SafeArea(
      bottom: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Text(
              strings.selectedServers(count),
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.close, size: 18),
              label: Text(strings.cancel),
              onPressed: onCancel,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(strings.delete),
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
                disabledBackgroundColor: colorScheme.error.withValues(
                  alpha: 0.12,
                ),
                disabledForegroundColor: colorScheme.error.withValues(
                  alpha: 0.38,
                ),
              ),
              onPressed: count > 0 ? onDelete : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerConnectionCard extends StatefulWidget {
  final ConnectionConfig conn;
  final SshConnectionOverview sessionSummary;
  final AppStrings strings;
  final int connIndex;
  final bool isSelected;
  final bool serverSelectionMode;
  final bool windowsExpanded;
  final bool isGrid;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<bool?>? onSelectedChanged;
  final VoidCallback onOpenNewTerminal;
  final VoidCallback onToggleConnectionWindows;
  final ValueChanged<String> onAction;

  const _ServerConnectionCard({
    required this.conn,
    required this.sessionSummary,
    required this.strings,
    required this.connIndex,
    required this.isSelected,
    required this.serverSelectionMode,
    required this.windowsExpanded,
    required this.isGrid,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectedChanged,
    required this.onOpenNewTerminal,
    required this.onToggleConnectionWindows,
    required this.onAction,
  });

  @override
  State<_ServerConnectionCard> createState() => _ServerConnectionCardState();
}

class _ServerConnectionCardState extends State<_ServerConnectionCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = mobileUiScaleOf(context);
    final isActive = widget.sessionSummary.hasConnected;
    final sessionCount = widget.sessionSummary.count;
    final latestState = widget.sessionSummary.latestState;
    final colorScheme = Theme.of(context).colorScheme;
    final primary = colorScheme.primary;
    final success = colorScheme.secondary;
    final cardColor = _panelColor(context);
    final textColor = _panelTextColor(context);
    final mutedTextColor = _panelMutedTextColor(context);
    final borderColor = isActive
        ? success.withValues(alpha: 0.42)
        : _panelBorderColor(context);

    final cardBgColor = widget.isSelected
        ? colorScheme.primary.withValues(alpha: 0.12)
        : cardColor;
    final activeBorderColor = widget.isSelected
        ? colorScheme.primary.withValues(alpha: 0.54)
        : borderColor;

    final actualWindowsExpanded =
        widget.windowsExpanded && !widget.isGrid && sessionCount > 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final extColors = Theme.of(context).extension<ExtendedColors>();
    final compactMobileCard = !widget.isGrid && !isDesktopLayout(context);

    final boxBorderColor = _isHovered
        ? (extColors?.cardHoverBorder ??
              colorScheme.primary.withValues(alpha: 0.34))
        : activeBorderColor;

    final boxBgColor = _isHovered
        ? Color.alphaBlend(
            colorScheme.primary.withValues(alpha: isDark ? 0.06 : 0.035),
            cardBgColor,
          )
        : cardBgColor;

    return MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: TactileFeedback(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              margin: EdgeInsets.only(bottom: widget.isGrid ? 0 : (6 * scale)),
              padding: EdgeInsets.all(
                widget.isGrid
                    ? 10 * scale
                    : (compactMobileCard ? 8 : 14) * scale,
              ),
              decoration: BoxDecoration(
                color: boxBgColor,
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                border: Border.all(color: boxBorderColor, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: _isHovered
                          ? (isDark ? 0.22 : 0.055)
                          : (isDark ? 0.16 : 0.025),
                    ),
                    blurRadius: _isHovered ? 18 : 10,
                    offset: Offset(0, _isHovered ? 7 : 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (!widget.serverSelectionMode && !widget.isGrid)
                        Padding(
                          padding: EdgeInsets.only(right: 4 * scale),
                          child: Tooltip(
                            message: widget.strings.reorderServer,
                            child: ReorderableDragStartListener(
                              index: widget.connIndex,
                              child: SizedBox.square(
                                key: ValueKey(
                                  'server-drag-handle-${widget.conn.id}',
                                ),
                                dimension: 48,
                                child: Icon(
                                  Icons.drag_handle_rounded,
                                  size: 20 * scale,
                                  color: mutedTextColor.withValues(alpha: 0.58),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (widget.serverSelectionMode)
                        Checkbox(
                          value: widget.isSelected,
                          onChanged: widget.onSelectedChanged,
                        ),
                      Container(
                        width: 36 * scale,
                        height: 36 * scale,
                        decoration: BoxDecoration(
                          color: isActive
                              ? success.withValues(alpha: 0.15)
                              : primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusSmall,
                          ),
                        ),
                        child: Icon(
                          _getStatusIcon(widget.conn, latestState),
                          color: isActive ? success : primary,
                          size: 20 * scale,
                        ),
                      ),
                      SizedBox(width: 12 * scale),
                      Expanded(
                        child: compactMobileCard
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  OverflowScrollText(
                                    widget.conn.name,
                                    selectable: false,
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: textColor,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: 2 * scale),
                                  Text(
                                    '${widget.conn.username}@${widget.conn.host}:${widget.conn.port}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: mutedTextColor,
                                    ),
                                  ),
                                ],
                              )
                            : OverflowScrollText(
                                widget.conn.name,
                                selectable: false,
                                maxLines: 1,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                      if (!widget.serverSelectionMode)
                        PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert,
                            color: mutedTextColor,
                            size: 20 * scale,
                          ),
                          onSelected: widget.onAction,
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'edit',
                              child: Row(
                                children: [
                                  Icon(Icons.edit, size: 18 * scale),
                                  SizedBox(width: 8 * scale),
                                  Text(widget.strings.edit),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.delete,
                                    size: 18 * scale,
                                    color: colorScheme.error,
                                  ),
                                  SizedBox(width: 8 * scale),
                                  Text(
                                    widget.strings.delete,
                                    style: TextStyle(color: colorScheme.error),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  if (!compactMobileCard) ...[
                    SizedBox(height: 8 * scale),
                    Row(
                      children: [
                        Icon(
                          Icons.dns_outlined,
                          size: 13 * scale,
                          color: mutedTextColor.withValues(alpha: 0.72),
                        ),
                        SizedBox(width: 5 * scale),
                        Flexible(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Text(
                              '${widget.conn.username}@${widget.conn.host}:${widget.conn.port}',
                              style: TextStyle(
                                fontSize: 13,
                                color: mutedTextColor,
                              ),
                            ),
                          ),
                        ),
                        if (sessionCount > 0) ...[
                          SizedBox(width: 8 * scale),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6 * scale,
                              vertical: 2 * scale,
                            ),
                            decoration: BoxDecoration(
                              color: success.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(
                                AppTheme.radiusPill,
                              ),
                            ),
                            child: Text(
                              widget.strings.language == AppLanguage.en
                                  ? '$sessionCount window${sessionCount == 1 ? "" : "s"}'
                                  : '$sessionCount 个窗口',
                              style: TextStyle(
                                color: success,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (!compactMobileCard) ...[
                    SizedBox(height: 6 * scale),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child:
                          Selector<
                            PerformanceMonitorService,
                            ServerHealthSnapshot
                          >(
                            selector: (_, monitor) =>
                                monitor.healthFor(widget.conn.id),
                            builder: (context, health, _) => _buildHealthChip(
                              context,
                              health,
                              widget.strings,
                            ),
                          ),
                    ),
                    SizedBox(height: 12 * scale),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    SizedBox(height: 8 * scale),
                  ] else
                    SizedBox(height: 2 * scale),
                  Row(
                    children: [
                      if (widget.isGrid) ...[
                        IconButton(
                          visualDensity: VisualDensity.standard,
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          tooltip: widget.strings.newWindow,
                          icon: Icon(
                            Icons.add_to_photos_outlined,
                            size: 16 * scale,
                          ),
                          onPressed: widget.onOpenNewTerminal,
                        ),
                        if (sessionCount > 0) ...[
                          const SizedBox(width: 4),
                          IconButton(
                            visualDensity: VisualDensity.standard,
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
                            ),
                            tooltip: widget.strings.windows,
                            icon: Icon(
                              Icons.terminal_outlined,
                              size: 16 * scale,
                            ),
                            onPressed: () => Navigator.pushNamed(
                              context,
                              '/terminal-windows',
                              arguments: widget.conn.id,
                            ),
                          ),
                        ],
                        const Spacer(),
                      ] else
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: TextButton.icon(
                                  onPressed: widget.onOpenNewTerminal,
                                  icon: Icon(
                                    Icons.add_to_photos_outlined,
                                    size: 16 * scale,
                                  ),
                                  label: Text(
                                    widget.strings.newWindow,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 8 * scale,
                                      vertical: 4 * scale,
                                    ),
                                  ),
                                ),
                              ),
                              if (sessionCount > 0) ...[
                                SizedBox(width: 8 * scale),
                                Flexible(
                                  child: TextButton.icon(
                                    onPressed: widget.onToggleConnectionWindows,
                                    icon: Icon(
                                      widget.windowsExpanded
                                          ? Icons.expand_less_rounded
                                          : Icons.expand_more_rounded,
                                      size: 16 * scale,
                                    ),
                                    label: Text(
                                      widget.strings.language == AppLanguage.en
                                          ? 'Window List · $sessionCount'
                                          : '窗口列表 · $sessionCount',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    style: TextButton.styleFrom(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8 * scale,
                                        vertical: 4 * scale,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                  if (actualWindowsExpanded)
                    TerminalWindowsPage(
                      key: PageStorageKey<String>(
                        'server-windows-${widget.conn.id}',
                      ),
                      connectionId: widget.conn.id,
                      showHeader: false,
                      embedded: true,
                    ),
                ],
              ),
            ),
          ),
        )
        .animate()
        .fade(duration: 250.ms)
        .slideY(
          begin: 0.08,
          end: 0,
          duration: 250.ms,
          curve: Curves.easeOutQuart,
        );
  }

  Widget _buildHealthChip(
    BuildContext context,
    ServerHealthSnapshot health,
    AppStrings strings,
  ) {
    final color = _healthColor(context, health.level);
    final label = _healthLabel(strings, health.level);
    final detail = health.details.isEmpty ? label : health.details.join(' / ');
    final text = health.level == ServerHealthLevel.unknown
        ? label
        : '${strings.language == AppLanguage.en ? 'Health' : '健康'} ${health.score} · $detail';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_healthIcon(health.level), size: 13, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
