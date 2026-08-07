import 'package:flutter/material.dart';

import 'connection_ui_tokens.dart';

/// 连接页面的柔和背景容器，避免页面直接暴露空白 Scaffold 背景。
final class ConnectionPageSurface extends StatelessWidget {
  const ConnectionPageSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final background = theme.scaffoldBackgroundColor;
    final topTint = Color.alphaBlend(
      colors.primary.withValues(alpha: isDark ? 0.045 : 0.022),
      background,
    );
    final bottomTint = Color.alphaBlend(
      colors.tertiary.withValues(alpha: isDark ? 0.025 : 0.012),
      background,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.5, 1],
          colors: [topTint, background, bottomTint],
        ),
      ),
      child: child,
    );
  }
}

/// 页面标题旁的图标徽章。
final class ConnectionIconBadge extends StatelessWidget {
  const ConnectionIconBadge({
    super.key,
    required this.icon,
    this.size = 48,
    this.iconSize = 24,
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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: 0.18),
            colors.tertiary.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
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
          ConnectionIconBadge(icon: icon!, size: 44, iconSize: 22),
          const SizedBox(width: 13),
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
                style: theme.textTheme.headlineSmall,
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
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
    this.contentGap = 14,
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
    final effectivePadding = padding ?? const EdgeInsets.all(20);
    final headerContent = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          ConnectionIconBadge(icon: icon!, size: 36, iconSize: 18),
          const SizedBox(width: 12),
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
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
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
                  constraints: const BoxConstraints(minHeight: 48),
                  child: headerContent,
                ),
              ),
            ),
          );

    return Card(
      clipBehavior: Clip.antiAlias,
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
