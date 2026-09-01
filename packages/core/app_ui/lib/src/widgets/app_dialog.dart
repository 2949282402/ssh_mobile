import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import '../theme/app_typography.dart';

/// 统一的基础对话框容器，符合现代开发者工具工作区标准。
///
/// 具备规范的标题、内容插槽与紧凑操作区；桌面端与移动端均保持克制设计与 8~12px 圆角。
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.titleWidget,
    this.subtitle,
    required this.child,
    this.actions,
    this.maxWidth = 440.0,
    this.contentPadding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
  });

  final String title;
  final Widget? titleWidget;
  final String? subtitle;
  final Widget child;
  final List<Widget>? actions;
  final double maxWidth;
  final EdgeInsetsGeometry contentPadding;

  /// 弹出标准通用对话框。
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    Widget? titleWidget,
    String? subtitle,
    required Widget child,
    List<Widget>? actions,
    double maxWidth = 440.0,
  }) {
    return showDialog<T>(
      context: context,
      builder: (context) => AppDialog(
        title: title,
        titleWidget: titleWidget,
        subtitle: subtitle,
        maxWidth: maxWidth,
        actions: actions,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final typography = AppTypography.of(context);

    return Dialog(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: contentPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (titleWidget != null)
                titleWidget!
              else
                Text(title, style: typography.sectionTitle),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle!, style: typography.metadata),
              ],
              const SizedBox(height: AppSpacing.md),
              Flexible(child: SingleChildScrollView(child: child)),
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (var i = 0; i < actions!.length; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.sm),
                      actions![i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一的确认对话框，符合开发者工具标准。
///
/// 具备清晰的标题、描述与操作按钮；桌面端为紧凑无多余修饰的对话框，
/// 移动端支持自适应或统一弹出。
class AppConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String cancelLabel;
  final String confirmLabel;
  final bool isDestructive;

  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.cancelLabel,
    required this.confirmLabel,
    this.isDestructive = false,
  });

  /// 显示确认框并将取消、关闭和确认统一转换为布尔结果。
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String content,
    required String cancelLabel,
    required String confirmLabel,
    bool isDestructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AppConfirmDialog(
        title: title,
        content: content,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        isDestructive: isDestructive,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final typography = AppTypography.of(context);

    return AlertDialog(
      title: Text(title, style: typography.sectionTitle),
      content: Text(
        content,
        style: typography.body.copyWith(color: colors.onSurfaceVariant),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: isDestructive
              ? TextButton.styleFrom(foregroundColor: colors.error)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// 统一的错误提示对话框。
class AppErrorDialog extends StatelessWidget {
  const AppErrorDialog({
    super.key,
    required this.title,
    required this.message,
    this.details,
    this.closeLabel = 'Close',
  });

  final String title;
  final String message;
  final String? details;
  final String closeLabel;

  /// 弹出错误对话框。
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String message,
    String? details,
    String closeLabel = 'Close',
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => AppErrorDialog(
        title: title,
        message: message,
        details: details,
        closeLabel: closeLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final typography = AppTypography.of(context);

    return AlertDialog(
      title: Text(title, style: typography.sectionTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: typography.body.copyWith(color: colors.onSurfaceVariant),
          ),
          if (details != null && details!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              ),
              child: SelectableText(
                details!,
                style: typography.codeSmall.copyWith(color: colors.error),
              ),
            ),
          ],
        ],
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(closeLabel),
        ),
      ],
    );
  }
}

/// 统一的移动端 BottomSheet 容器，具备拖拽条、12px 圆角与标准触控区域。
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({
    super.key,
    this.title,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });

  final String? title;
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 弹出统一移动端 BottomSheet。
  static Future<T?> show<T>({
    required BuildContext context,
    String? title,
    required Widget child,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusLarge),
        ),
      ),
      builder: (context) => AppBottomSheet(title: title, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final typography = AppTypography.of(context);

    return SafeArea(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                decoration: BoxDecoration(
                  color: colors.outlineVariant,
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
              ),
            ),
            if (title != null) ...[
              Text(title!, style: typography.sectionTitle),
              const SizedBox(height: AppSpacing.md),
            ],
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}
