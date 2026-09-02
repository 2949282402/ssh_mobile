import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'app_surface.dart';
import 'overflow_scroll_text.dart';
import 'tactile_feedback.dart';

typedef AppServerSelectorTileBuilder<T> =
    Widget Function(BuildContext context, T connection, bool compact);

/// 展开式服务器选择面板（支持桌面端与移动端抽屉/全屏展示）。
class AppServerSelectorPane<T> extends StatelessWidget {
  const AppServerSelectorPane({
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
    required this.itemKeyBuilder,
    required this.emptyState,
    this.collapseButtonKey,
    this.dragHandleKeyBuilder,
    this.collapseIcon = Icons.keyboard_double_arrow_left_rounded,
  });

  final List<T> connections;
  final String title;
  final String subtitle;
  final IconData headerIcon;
  final String collapseTooltip;
  final String reorderTooltip;
  final VoidCallback? onCollapse;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final AppServerSelectorTileBuilder<T> tileBuilder;
  final Key Function(T connection) itemKeyBuilder;
  final Widget emptyState;
  final Key? collapseButtonKey;
  final Key Function(T connection)? dragHandleKeyBuilder;
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
                      key: itemKeyBuilder(connection),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final showDragHandle = constraints.maxWidth >= 96;
                          return Row(
                            children: [
                              if (showDragHandle)
                                Tooltip(
                                  message: reorderTooltip,
                                  child: Semantics(
                                    label: reorderTooltip,
                                    button: true,
                                    child: ExcludeSemantics(
                                      child: ReorderableDragStartListener(
                                        index: index,
                                        child: SizedBox.square(
                                          key: dragHandleKeyBuilder?.call(
                                            connection,
                                          ),
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
                          );
                        },
                      ),
                    );
                  },
                  onReorderItem: onReorder ?? (_, _) {},
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 移动端紧凑横向服务器快速选择条。
class AppServerSelectorStrip<T> extends StatelessWidget {
  const AppServerSelectorStrip({
    super.key,
    required this.connections,
    required this.semanticsLabel,
    required this.noConnectionsLabel,
    required this.collapseTooltip,
    required this.onCollapse,
    required this.tileBuilder,
    this.collapseButtonKey,
    this.collapseIcon = Icons.keyboard_double_arrow_up_rounded,
  });

  final List<T> connections;
  final String semanticsLabel;
  final String noConnectionsLabel;
  final String collapseTooltip;
  final VoidCallback onCollapse;
  final AppServerSelectorTileBuilder<T> tileBuilder;
  final Key? collapseButtonKey;
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

/// 移动端折叠后的顶部单行概览栏。
class AppServerSummaryBar extends StatelessWidget {
  const AppServerSummaryBar({
    super.key,
    required this.title,
    this.subtitle,
    required this.statusIcon,
    required this.expandTooltip,
    required this.onExpand,
    this.expandButtonKey,
    this.expandIcon = Icons.keyboard_double_arrow_down_rounded,
    this.semanticsLabel,
    this.semanticsKey,
  });

  final String title;
  final String? subtitle;
  final Widget statusIcon;
  final String expandTooltip;
  final VoidCallback onExpand;
  final Key? expandButtonKey;
  final IconData expandIcon;
  final String? semanticsLabel;
  final Key? semanticsKey;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 2.0).toDouble();
    final barHeight = 48.0 + (textScale - 1.0) * 22.0;
    final summaryText = subtitle != null && subtitle!.isNotEmpty
        ? '$title  $subtitle'
        : title;

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
                    key: expandButtonKey,
                    tooltip: expandTooltip,
                    icon: Icon(expandIcon),
                    onPressed: onExpand,
                  ),
                ),
                const SizedBox(width: 8),
                statusIcon,
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    key: semanticsKey,
                    container: true,
                    label: semanticsLabel ?? summaryText,
                    child: ExcludeSemantics(
                      child: OverflowScrollText(
                        summaryText,
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

/// 标准服务器卡片（支持 compact 与 expanded 展现）。
class AppServerTile extends StatelessWidget {
  const AppServerTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.leading,
    this.statusWidget,
    this.trailing,
    this.selected = false,
    this.busy = false,
    this.compact = false,
    this.onTap,
    this.semanticsLabel,
    this.semanticsKey,
    this.accentColor,
    this.showEndpointIcon = true,
  });

  final String title;
  final String? subtitle;
  final Widget leading;
  final Widget? statusWidget;
  final Widget? trailing;
  final bool selected;
  final bool busy;
  final bool compact;
  final VoidCallback? onTap;
  final String? semanticsLabel;
  final Key? semanticsKey;
  final Color? accentColor;
  final bool showEndpointIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final scale = mobileUiScaleOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final stackStatus = !compact && textScale >= 1.5;
    final isDark = theme.brightness == Brightness.dark;
    final themeColor = accentColor ?? colorScheme.primary;

    final borderColor = selected
        ? themeColor.withValues(alpha: 0.58)
        : compact
        ? colorScheme.outlineVariant
        : colorScheme.outline.withValues(alpha: 0.62);

    final background = compact
        ? (selected ? themeColor.withValues(alpha: 0.08) : colorScheme.surface)
        : selected
        ? Color.alphaBlend(
            themeColor.withValues(alpha: isDark ? 0.12 : 0.075),
            colorScheme.surfaceContainerLow,
          )
        : colorScheme.surfaceContainerLow.withValues(alpha: 0.76);

    final titleWidget = OverflowScrollText(
      title,
      selectable: false,
      maxLines: 1,
      style: TextStyle(
        color: colorScheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    );

    final endpointWidget = subtitle != null && subtitle!.isNotEmpty
        ? LayoutBuilder(
            builder: (context, constraints) {
              final showIcon = showEndpointIcon && constraints.maxWidth >= 40;
              return Row(
                children: [
                  if (showIcon) ...[
                    Icon(
                      Icons.dns_outlined,
                      size: 13 * scale,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    SizedBox(width: 5 * scale),
                  ],
                  Expanded(
                    child: OverflowScrollText(
                      subtitle!,
                      selectable: false,
                      maxLines: 1,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              );
            },
          )
        : null;

    return Semantics(
      key: semanticsKey,
      container: true,
      button: true,
      enabled: !busy,
      selected: selected,
      label: semanticsLabel ?? (subtitle != null ? '$title, $subtitle' : title),
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
            ),
            child: LayoutBuilder(
              builder: (context, tileConstraints) {
                final showLeading = tileConstraints.maxWidth >= 60;
                return Row(
                  children: [
                    if (showLeading) ...[leading, SizedBox(width: 10 * scale)],
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final showInlineTrailing =
                              !compact &&
                              !stackStatus &&
                              trailing != null &&
                              constraints.maxWidth >= 150;
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (compact || trailing == null) ...[
                                titleWidget,
                                if (statusWidget != null && !compact) ...[
                                  SizedBox(height: 2 * scale),
                                  statusWidget!,
                                ],
                                if (endpointWidget != null) ...[
                                  SizedBox(height: 3 * scale),
                                  endpointWidget,
                                ],
                              ] else if (showInlineTrailing) ...[
                                Row(
                                  children: [
                                    Expanded(child: titleWidget),
                                    SizedBox(width: 8 * scale),
                                    trailing!,
                                  ],
                                ),
                                if (endpointWidget != null) ...[
                                  SizedBox(height: 5 * scale),
                                  endpointWidget,
                                ],
                              ] else ...[
                                titleWidget,
                                if (statusWidget != null) ...[
                                  SizedBox(height: 2 * scale),
                                  statusWidget!,
                                ],
                                if (endpointWidget != null) ...[
                                  SizedBox(height: 3 * scale),
                                  endpointWidget,
                                ],
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
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
    this.collapseButtonKey,
    required this.collapseIcon,
    required this.onCollapse,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String collapseTooltip;
  final Key? collapseButtonKey;
  final IconData collapseIcon;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final isUltraNarrow = availableWidth < 80;
        final isNarrow = availableWidth < 140;
        final horizontalPadding = isUltraNarrow ? 4.0 : 12.0;

        final collapseButton = SizedBox.square(
          dimension: isUltraNarrow ? 36 : 48,
          child: IconButton(
            key: collapseButtonKey,
            tooltip: collapseTooltip,
            iconSize: isUltraNarrow ? 18 : 24,
            padding: EdgeInsets.zero,
            icon: Icon(collapseIcon),
            onPressed: onCollapse,
          ),
        );

        if (isUltraNarrow) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              12,
              horizontalPadding,
              10,
            ),
            child: Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: collapseButton),
            ),
          );
        }

        final textColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 14,
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
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            12,
            horizontalPadding,
            10,
          ),
          child: Row(
            children: [
              if (!isNarrow) ...[
                AppIconBadge(icon: icon, size: 36, iconSize: 18),
                const SizedBox(width: 10),
              ],
              Expanded(child: textColumn),
              collapseButton,
            ],
          ),
        );
      },
    );
  }
}

class _ServerSelectorCollapseButton extends StatelessWidget {
  const _ServerSelectorCollapseButton({
    this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key? buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 48,
      child: Align(
        alignment: Alignment.center,
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
