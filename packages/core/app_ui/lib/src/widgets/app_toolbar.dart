import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// 统一的工具栏组件，符合现代专业开发者工具工作区标准。
///
/// 具备 40~48dp 高度、16~18dp 紧凑图标、8~12dp 间距及清晰的操作分组。
class AppToolbar extends StatelessWidget implements PreferredSizeWidget {
  const AppToolbar({
    super.key,
    this.leading,
    this.title,
    this.titleText,
    this.actions,
    this.height = 44.0,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpacing.md),
    this.showBottomBorder = true,
    this.backgroundColor,
    this.borderColor,
  });

  final Widget? leading;
  final Widget? title;
  final String? titleText;
  final List<Widget>? actions;
  final double height;
  final EdgeInsetsGeometry padding;
  final bool showBottomBorder;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bg = backgroundColor ?? colors.surface;
    final border = borderColor ?? colors.outlineVariant.withValues(alpha: 0.6);

    Widget? effectiveTitle = title;
    if (effectiveTitle == null && titleText != null) {
      effectiveTitle = Text(
        titleText!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
          color: colors.onSurface,
        ),
      );
    }

    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        border: showBottomBorder
            ? Border(bottom: BorderSide(color: border, width: 1))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.sm),
          ],
          if (effectiveTitle != null) ...[
            Expanded(child: effectiveTitle),
          ] else ...[
            const Spacer(),
          ],
          if (actions != null && actions!.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.sm),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: actions!,
            ),
          ],
        ],
      ),
    );
  }
}

/// 工具栏中的紧凑操作按钮。
class AppToolbarAction extends StatelessWidget {
  const AppToolbarAction({
    super.key,
    required this.icon,
    this.label,
    this.tooltip,
    this.onPressed,
    this.isSelected = false,
    this.isDestructive = false,
    this.iconSize = 16.0,
    this.badge,
  });

  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool isSelected;
  final bool isDestructive;
  final double iconSize;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    Color fg;
    if (onPressed == null) {
      fg = colors.onSurfaceVariant.withValues(alpha: 0.38);
    } else if (isDestructive) {
      fg = colors.error;
    } else if (isSelected) {
      fg = colors.primary;
    } else {
      fg = colors.onSurfaceVariant;
    }

    final bg = isSelected
        ? colors.primary.withValues(alpha: 0.12)
        : Colors.transparent;

    Widget buttonContent = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: iconSize, color: fg),
        if (label != null) ...[
          const SizedBox(width: AppSpacing.xs),
          Text(
            label!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: fg,
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ],
    );

    if (badge != null) {
      buttonContent = Stack(
        clipBehavior: Clip.none,
        children: [
          buttonContent,
          Positioned(top: -4, right: -4, child: badge!),
        ],
      );
    }

    final button = Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Center(child: buttonContent),
          ),
        ),
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      return Tooltip(message: tooltip!, child: button);
    }

    return button;
  }
}

/// 工具栏操作分组容器，支持在操作组之间自动渲染克制的垂直分割线。
class AppToolbarGroup extends StatelessWidget {
  const AppToolbarGroup({
    super.key,
    required this.children,
    this.spacing = AppSpacing.xs,
    this.showTrailingDivider = false,
  });

  final List<Widget> children;
  final double spacing;
  final bool showTrailingDivider;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          children[i],
        ],
        if (showTrailingDivider) ...[
          const SizedBox(width: AppSpacing.sm),
          Container(
            width: 1,
            height: 16,
            color: colors.outlineVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ],
    );
  }
}
