import 'package:flutter/material.dart';

import 'connection_ui_tokens.dart';

/// 连接页面的柔和背景容器，避免页面直接暴露空白 Scaffold 背景。
final class ConnectionPageSurface extends StatelessWidget {
  const ConnectionPageSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.scaffoldBackgroundColor;

    return Material(color: background, type: MaterialType.canvas, child: child);
  }
}

/// 页面标题旁的图标徽章。
final class ConnectionIconBadge extends StatelessWidget {
  const ConnectionIconBadge({
    super.key,
    required this.icon,
    this.size = 32,
    this.iconSize = 16,
  });

  final IconData icon;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ConnectionUiTokens.radiusSmall),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.14),
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: colors.primary),
    );
  }
}

/// 连接页面的标题布局。
final class ConnectionPageHeader extends StatelessWidget {
  const ConnectionPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          ConnectionIconBadge(icon: icon!, size: 32, iconSize: 16),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 可折叠的连接配置分组卡片。
final class ConnectionSectionCard extends StatelessWidget {
  const ConnectionSectionCard({
    super.key,
    required this.title,
    this.child,
    this.icon,
    this.subtitle,
    this.onHeaderTap,
    this.expanded,
    this.padding,
    this.contentGap = 12,
  }) : assert(
         onHeaderTap == null || expanded != null,
         'expanded must be provided when the header is interactive',
       );

  final String title;
  final Widget? child;
  final IconData? icon;
  final String? subtitle;
  final VoidCallback? onHeaderTap;
  final bool? expanded;
  final EdgeInsetsGeometry? padding;
  final double contentGap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final effectivePadding = padding ?? const EdgeInsets.all(16);
    final headerContent = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon!, size: 18, color: colors.primary),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (onHeaderTap != null)
          ExcludeSemantics(
            child: Icon(
              expanded! ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: colors.onSurfaceVariant,
            ),
          ),
      ],
    );

    final header = onHeaderTap == null
        ? headerContent
        : Semantics(
            container: true,
            label: title,
            button: true,
            expanded: expanded,
            onTap: onHeaderTap,
            child: ExcludeSemantics(
              child: InkWell(
                onTap: onHeaderTap,
                borderRadius: BorderRadius.circular(
                  ConnectionUiTokens.radiusSmall,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: headerContent,
                ),
              ),
            ),
          );

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ConnectionUiTokens.radiusMedium),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      child: Padding(
        padding: effectivePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (child != null) ...[SizedBox(height: contentGap), child!],
          ],
        ),
      ),
    );
  }
}
