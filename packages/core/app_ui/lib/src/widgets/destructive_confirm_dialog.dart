import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 统一的破坏性操作确认对话框；文案由业务 Feature 注入。
class DestructiveConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String cancelLabel;
  final String confirmLabel;

  const DestructiveConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  /// 显示确认框并将取消、关闭和确认统一转换为布尔结果。
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String content,
    required String cancelLabel,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => DestructiveConfirmDialog(
        title: title,
        content: content,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: Text(title),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        ShadButton.destructive(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
      child: Text(content),
    );
  }
}
