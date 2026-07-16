import 'package:flutter/material.dart';

import 'package:ssh_mobile/theme/app_theme.dart';

/// A quiet tonal backdrop shared by the app's primary workspaces.
///
/// The gradient is intentionally subtle so dense terminal and monitoring
/// content remains the visual focus while empty and loading states do not feel
/// like they are floating on an unfinished white canvas.
class AppPageSurface extends StatelessWidget {
  const AppPageSurface({super.key, required this.child});

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

class AppIconBadge extends StatelessWidget {
  const AppIconBadge({
    super.key,
    required this.icon,
    this.size = 48,
    this.iconSize = 24,
    this.color,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = color ?? colors.primary;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.18),
            colors.tertiary.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: accent),
    );
  }
}

class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          AppIconBadge(icon: icon!, size: 44, iconSize: 22),
          const SizedBox(width: 13),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
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
        if (trailing != null) ...[const SizedBox(width: 16), trailing!],
      ],
    );
  }
}

class AppSectionCard extends StatelessWidget {
  const AppSectionCard({
    super.key,
    required this.title,
    this.child,
    this.icon,
    this.subtitle,
    this.trailing,
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
  final Widget? trailing;
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
          AppIconBadge(icon: icon!, size: 36, iconSize: 18),
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
                  letterSpacing: 0,
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
          )
        else if (trailing != null) ...[
          const SizedBox(width: 12),
          trailing!,
        ],
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
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondaryAction,
    this.compact = false,
    this.contained = true,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final Widget? secondaryAction;
  final bool compact;
  final bool contained;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final content = SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.all(compact ? 22 : 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconBadge(
              icon: icon,
              size: compact ? 60 : 72,
              iconSize: compact ? 30 : 34,
            ),
            SizedBox(height: compact ? 16 : 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (action != null || secondaryAction != null) ...[
              SizedBox(height: compact ? 18 : 22),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [?action, ?secondaryAction],
              ),
            ],
          ],
        ),
      ),
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: contained
            ? Container(
                margin: const EdgeInsets.all(AppTheme.compactPagePadding),
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: isDark ? 0.74 : 0.9),
                  borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                  border: Border.all(
                    color: colors.outline.withValues(alpha: 0.72),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.20 : 0.045,
                      ),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: content,
              )
            : content,
      ),
    );
  }
}
