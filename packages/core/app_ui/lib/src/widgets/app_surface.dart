import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 跨 Feature 复用的页面背景组件。
///
/// 纯色中性底色背景，去除了多余的色彩渐变与视觉装饰，
/// 保持高信息密度的开发者工具基底。
class AppPageSurface extends StatelessWidget {
  const AppPageSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.scaffoldBackgroundColor;

    return Material(color: background, type: MaterialType.canvas, child: child);
  }
}

/// 轻量级图标容器，用于需要微弱底色衬托的场景。
///
/// 默认无渐变、无强阴影，采用克制的中性或语义强调微底色。
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({
    super.key,
    required this.icon,
    this.size = 32,
    this.iconSize = 16,
    this.color,
    this.backgroundColor,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = color ?? colors.primary;
    final bg = backgroundColor ?? accent.withValues(alpha: 0.08);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: accent.withValues(alpha: 0.12), width: 1),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: accent),
    );
  }
}

/// 提供统一的标题、副标题和尾部操作布局。
///
/// 默认采用紧凑、克制的专业工具标题样式，图标为可选呈现。
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.icon,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
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
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 10),
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
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitleWidget != null) ...[
                const SizedBox(height: 2),
                subtitleWidget!,
              ] else if (subtitle != null && subtitle!.isNotEmpty) ...[
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
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

/// 非卡片式的结构化区块，仅负责组织标题、操作和内容间距。
class AppSection extends StatelessWidget {
  const AppSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.padding,
    this.headerGap = 8,
  });

  final String title;
  final Widget child;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final double headerGap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          SizedBox(height: headerGap),
          child,
        ],
      ),
    );
  }
}

/// 独立的内容面板 Surface，用于需要独立层级或边框包裹的工作区面板。
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin,
    this.backgroundColor,
    this.borderColor,
    this.borderRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? backgroundColor;
  final Color? borderColor;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? colors.surface,
        borderRadius:
            borderRadius ?? BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: borderColor ?? colors.outlineVariant.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      child: child,
    );
  }
}

/// 统一的可选折叠区块卡片；展开状态由调用方持有。
///
/// 边框极细、0 elevation、0 shadow，保持紧凑和专业感。
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
    this.contentGap = 10,
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
    final effectivePadding = padding ?? const EdgeInsets.all(14);

    final headerContent = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 8),
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
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          )
        else if (trailing != null) ...[
          const SizedBox(width: 8),
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
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
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

/// 展示列表或工作区的空状态，并可提供主次操作。
///
/// 紧凑克制设计，移除 72px 大渐变图标和 28px 阴影。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondaryAction,
    this.compact = false,
    this.contained = false,
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
    final content = SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: compact ? 28 : 36,
              color: colors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            SizedBox(height: compact ? 12 : 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
            if (action != null || secondaryAction != null) ...[
              SizedBox(height: compact ? 14 : 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [?action, ?secondaryAction],
              ),
            ],
          ],
        ),
      ),
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: contained
            ? Container(
                margin: const EdgeInsets.all(AppTheme.compactPagePadding),
                decoration: BoxDecoration(
                  color: colors.surfaceContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.6),
                    width: 1,
                  ),
                ),
                child: content,
              )
            : content,
      ),
    );
  }
}
