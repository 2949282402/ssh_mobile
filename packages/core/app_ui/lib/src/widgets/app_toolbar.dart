import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';

/// 工具栏子项契约，表示该组件是符合 Design System 规范的工具栏元素。
abstract interface class AppToolbarItem implements Widget {}

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

enum _AppToolbarActionVariant { adaptive, compact, touch }

/// 工具栏中的操作按钮，支持响应式 Touch Target（移动端 >=44dp，桌面端 32~36dp）。
class AppToolbarAction extends StatelessWidget implements AppToolbarItem {
  /// 默认自适应构造函数：在移动触控平台上保证 >=44dp 触控热区，在桌面端保持 32dp 紧凑布局。
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
    this.minWidth,
    this.minHeight,
  }) : _variant = _AppToolbarActionVariant.adaptive;

  /// 显式紧凑模式构造函数：固定 32dp 紧凑尺寸。
  const AppToolbarAction.compact({
    super.key,
    required this.icon,
    this.label,
    this.tooltip,
    this.onPressed,
    this.isSelected = false,
    this.isDestructive = false,
    this.iconSize = 16.0,
    this.badge,
    this.minWidth,
    this.minHeight,
  }) : _variant = _AppToolbarActionVariant.compact;

  /// 显式触控友好模式构造函数：固定 >=44dp 触控尺寸。
  const AppToolbarAction.touch({
    super.key,
    required this.icon,
    this.label,
    this.tooltip,
    this.onPressed,
    this.isSelected = false,
    this.isDestructive = false,
    this.iconSize = 16.0,
    this.badge,
    this.minWidth,
    this.minHeight,
  }) : _variant = _AppToolbarActionVariant.touch;

  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool isSelected;
  final bool isDestructive;
  final double iconSize;
  final Widget? badge;
  final double? minWidth;
  final double? minHeight;
  final _AppToolbarActionVariant _variant;

  double _resolveMinDimension(BuildContext context, {required bool isWidth}) {
    if (isWidth && minWidth != null) return minWidth!;
    if (!isWidth && minHeight != null) return minHeight!;

    return switch (_variant) {
      _AppToolbarActionVariant.compact => 32.0,
      _AppToolbarActionVariant.touch => 44.0,
      _AppToolbarActionVariant.adaptive =>
        isTouchPlatform(Theme.of(context).platform) ? 44.0 : 32.0,
    };
  }

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

    final effectiveMinWidth = _resolveMinDimension(context, isWidth: true);
    final effectiveMinHeight = _resolveMinDimension(context, isWidth: false);
    final isTouchSized = effectiveMinHeight >= 44.0;

    final button = Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: effectiveMinWidth,
            minHeight: effectiveMinHeight,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isTouchSized ? AppSpacing.md : AppSpacing.sm,
              vertical: isTouchSized ? AppSpacing.sm : AppSpacing.xs,
            ),
            child: Center(
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: buttonContent,
            ),
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
class AppToolbarGroup extends StatelessWidget implements AppToolbarItem {
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

/// 工具栏操作列表容器组件。
///
/// 统一管理一组工具栏操作或操作组，提供标准间距与对齐。
class AppToolbarActions extends StatelessWidget implements AppToolbarItem {
  const AppToolbarActions({
    super.key,
    required this.children,
    this.spacing = AppSpacing.xs,
  });

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          children[i],
        ],
      ],
    );
  }
}
