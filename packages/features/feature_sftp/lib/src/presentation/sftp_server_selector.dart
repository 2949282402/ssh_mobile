import 'package:flutter/material.dart';

import 'package:app_ui/app_ui.dart';

import '../domain/sftp_models.dart';

typedef ServerSelectorTileBuilder =
    Widget Function(
      BuildContext context,
      SftpConnectionInfo connection,
      bool compact,
    );

/// Shared expanded server selector used by SFTP and System Administration.
class ServerSelectorPane extends StatelessWidget {
  const ServerSelectorPane({
    super.key,
    required this.connections,
    required this.title,
    required this.subtitle,
    required this.headerIcon,
    required this.collapseTooltip,
    required this.reorderTooltip,
    required this.onCollapse,
    required this.onReorder,
    required this.tileBuilder,
    required this.emptyState,
    required this.collapseButtonKey,
    this.dragHandleKeyBuilder,
    this.collapseIcon = Icons.keyboard_double_arrow_left_rounded,
  });

  final List<SftpConnectionInfo> connections;
  final String title;
  final String subtitle;
  final IconData headerIcon;
  final String collapseTooltip;
  final String reorderTooltip;
  final VoidCallback onCollapse;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ServerSelectorTileBuilder tileBuilder;
  final Widget emptyState;
  final Key collapseButtonKey;
  final Key Function(SftpConnectionInfo connection)? dragHandleKeyBuilder;
  final IconData collapseIcon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          _ServerSelectorHeader(
            title: title,
            subtitle: subtitle,
            icon: headerIcon,
            collapseTooltip: collapseTooltip,
            collapseButtonKey: collapseButtonKey,
            collapseIcon: collapseIcon,
            onCollapse: connections.isEmpty ? null : onCollapse,
          ),
          if (connections.isEmpty)
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                children: [emptyState],
              ),
            )
          else
            Expanded(
              child: Scrollbar(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.fromLTRB(8, 0, 12, 24),
                  itemCount: connections.length,
                  itemBuilder: (context, index) {
                    final connection = connections[index];
                    return Padding(
                      key: ValueKey(connection.id),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Tooltip(
                            message: reorderTooltip,
                            child: Semantics(
                              label: reorderTooltip,
                              button: true,
                              child: ExcludeSemantics(
                                child: ReorderableDragStartListener(
                                  index: index,
                                  child: SizedBox.square(
                                    key: dragHandleKeyBuilder?.call(connection),
                                    dimension: 48,
                                    child: Icon(
                                      Icons.drag_handle_rounded,
                                      size: 20,
                                      color: colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.58),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: tileBuilder(context, connection, false),
                          ),
                        ],
                      ),
                    );
                  },
                  onReorderItem: onReorder,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shared horizontal server selector used by compact/mobile layouts.
class ServerSelectorStrip extends StatelessWidget {
  const ServerSelectorStrip({
    super.key,
    required this.connections,
    required this.semanticsLabel,
    required this.noConnectionsLabel,
    required this.collapseTooltip,
    required this.onCollapse,
    required this.tileBuilder,
    required this.collapseButtonKey,
    this.collapseIcon = Icons.keyboard_double_arrow_up_rounded,
  });

  final List<SftpConnectionInfo> connections;
  final String semanticsLabel;
  final String noConnectionsLabel;
  final String collapseTooltip;
  final VoidCallback onCollapse;
  final ServerSelectorTileBuilder tileBuilder;
  final Key collapseButtonKey;
  final IconData collapseIcon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 2.0).toDouble();
    final stripHeight = 72.0 + (textScale - 1.0) * 38.0;
    if (connections.isEmpty) {
      return SizedBox(
        height: stripHeight,
        child: Center(child: Text(noConnectionsLabel)),
      );
    }

    return Material(
      color: colorScheme.surface,
      child: SizedBox(
        height: stripHeight,
        child: Semantics(
          container: true,
          label: semanticsLabel,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            scrollDirection: Axis.horizontal,
            itemCount: connections.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _ServerSelectorCollapseButton(
                  buttonKey: collapseButtonKey,
                  tooltip: collapseTooltip,
                  icon: collapseIcon,
                  onPressed: onCollapse,
                );
              }
              final connection = connections[index - 1];
              return SizedBox(
                width: 210,
                child: tileBuilder(context, connection, true),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ServerSelectorHeader extends StatelessWidget {
  const _ServerSelectorHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.collapseTooltip,
    required this.collapseButtonKey,
    required this.collapseIcon,
    required this.onCollapse,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String collapseTooltip;
  final Key collapseButtonKey;
  final IconData collapseIcon;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Row(
        children: [
          AppIconBadge(icon: icon, size: 36, iconSize: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          SizedBox.square(
            dimension: 48,
            child: IconButton(
              key: collapseButtonKey,
              tooltip: collapseTooltip,
              icon: Icon(collapseIcon),
              onPressed: onCollapse,
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerSelectorCollapseButton extends StatelessWidget {
  const _ServerSelectorCollapseButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 48,
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox.square(
          dimension: 48,
          child: Material(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: IconButton(
              key: buttonKey,
              tooltip: tooltip,
              icon: Icon(icon),
              onPressed: onPressed,
            ),
          ),
        ),
      ),
    );
  }
}
