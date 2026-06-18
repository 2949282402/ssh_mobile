import 'package:flutter/material.dart';

import 'countdown_confirm_dialog.dart';
import 'destructive_confirm_dialog.dart';
import 'typed_confirm_dialog.dart';

part 'system_power_confirmation_token.dart';

enum SystemPowerAction { reboot, shutdown }

Future<SystemPowerConfirmationToken?> confirmSystemPowerAction(
  BuildContext context, {
  required SystemPowerAction action,
  required bool isEnglish,
}) async {
  final requiredText = switch (action) {
    SystemPowerAction.reboot => '我确认需要重启系统',
    SystemPowerAction.shutdown => '我确认需要关机',
  };
  final cancelLabel = isEnglish ? 'Cancel' : '取消';
  final confirmLabel = isEnglish ? 'Confirm' : '确定';

  final firstConfirmed = await DestructiveConfirmDialog.show(
    context,
    title: switch (action) {
      SystemPowerAction.reboot =>
        isEnglish ? 'Confirm system reboot?' : '确认重启系统？',
      SystemPowerAction.shutdown =>
        isEnglish ? 'Confirm system shutdown?' : '确认关闭系统？',
    },
    content: switch (action) {
      SystemPowerAction.reboot => isEnglish
          ? 'Rebooting will interrupt current server connections and running tasks. Continue?'
          : '重启会中断当前服务器连接和运行中的任务。是否继续？',
      SystemPowerAction.shutdown => isEnglish
          ? 'Shutting down will interrupt current server connections and running tasks, and may not be remotely recoverable. Continue?'
          : '关机会中断当前服务器连接和运行中的任务，且可能无法远程恢复。是否继续？',
    },
    cancelLabel: cancelLabel,
    confirmLabel: confirmLabel,
  );
  if (!firstConfirmed || !context.mounted) return null;

  final typedConfirmed = await TypedConfirmDialog.show(
    context,
    title: isEnglish ? 'Type confirmation text' : '输入确认文本',
    content: isEnglish
        ? 'Type "$requiredText" to continue.'
        : '请输入“$requiredText”以继续。',
    requiredText: requiredText,
    cancelLabel: cancelLabel,
    confirmLabel: confirmLabel,
  );
  if (!typedConfirmed || !context.mounted) return null;

  final countdownConfirmed = await CountdownConfirmDialog.show(
    context,
    title: switch (action) {
      SystemPowerAction.reboot =>
        isEnglish ? 'Final reboot confirmation' : '最终确认重启',
      SystemPowerAction.shutdown =>
        isEnglish ? 'Final shutdown confirmation' : '最终确认关机',
    },
    content: switch (action) {
      SystemPowerAction.reboot => isEnglish
          ? 'You can confirm the reboot after the countdown finishes.'
          : '倒计时结束后才能确认执行重启。',
      SystemPowerAction.shutdown => isEnglish
          ? 'You can confirm the shutdown after the countdown finishes.'
          : '倒计时结束后才能确认执行关机。',
    },
    seconds: 10,
    cancelLabel: cancelLabel,
    confirmLabel: confirmLabel,
  );

  if (!countdownConfirmed) return null;

  final nonce = DateTime.now().microsecondsSinceEpoch.toString();
  return SystemPowerConfirmationToken._(
    action: action,
    issuedAt: DateTime.now(),
    nonce: nonce,
  );
}
