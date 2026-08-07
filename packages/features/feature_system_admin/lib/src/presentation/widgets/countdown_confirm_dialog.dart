// 高风险操作的倒计时确认对话框。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CountdownConfirmDialog extends StatefulWidget {
  final String title;
  final String content;
  final int seconds;
  final String cancelLabel;
  final String confirmLabel;

  const CountdownConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    this.seconds = 10,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String content,
    int seconds = 10,
    required String cancelLabel,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => CountdownConfirmDialog(
        title: title,
        content: content,
        seconds: seconds,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
      ),
    );
    return result ?? false;
  }

  @override
  State<CountdownConfirmDialog> createState() => _CountdownConfirmDialogState();
}

class _CountdownConfirmDialogState extends State<CountdownConfirmDialog> {
  Timer? _timer;
  late int _remainingSeconds;

  bool get _canConfirm => _remainingSeconds <= 0;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.seconds < 0 ? 0 : widget.seconds;
    if (_remainingSeconds > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_remainingSeconds <= 1) {
          timer.cancel();
          setState(() => _remainingSeconds = 0);
          return;
        }
        setState(() => _remainingSeconds -= 1);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final confirmText = _canConfirm
        ? widget.confirmLabel
        : '${widget.confirmLabel} ($_remainingSeconds)';
    return ShadDialog(
      title: Text(widget.title),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.pop(context, false),
          child: Text(widget.cancelLabel),
        ),
        ShadButton.destructive(
          onPressed: _canConfirm ? () => Navigator.pop(context, true) : null,
          child: Text(confirmText),
        ),
      ],
      child: Text(widget.content),
    );
  }
}
