import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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

    return AlertDialog(
      title: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
      content: Text(
        content,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
          fontSize: 14,
          height: 1.4,
        ),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: isDestructive
              ? FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
