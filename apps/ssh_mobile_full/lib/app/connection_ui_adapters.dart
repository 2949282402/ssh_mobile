// ignore_for_file: prefer_initializing_formals

import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_connection/feature_connection.dart';
import 'package:flutter/material.dart';

import '../core/services/ssh_host_key_policy.dart';
import '../services/app_log_service.dart';
import '../widgets/ssh_host_key_trust_dialog.dart';

/// App UI 到 Connection Feature 展示契约的适配器。
final class AppConnectionUiAdapter implements ConnectionUiAdapter {
  @override
  Future<bool> confirmHostKey(
    BuildContext context,
    ConnectionHostKeyPrompt prompt,
  ) {
    return showSshHostKeyTrustDialog(context, _toLegacyPrompt(prompt));
  }

  @override
  void logSaveFailure({
    required Object error,
    required StackTrace stackTrace,
    required connection_core.ConnectionConfig? config,
  }) {
    AppLogService.instance.error(
      'Failed to save connection config or verify SSH login',
      error: error,
      stackTrace: stackTrace,
      details: config == null
          ? null
          : 'host=${config.host} port=${config.port} user=${config.username} '
                'authMethod=${config.authMethod.name}',
    );
  }
}

/// 将 Feature Host Key 提示转换为旧 SSH 对话框模型。
SshHostKeyPromptRequest _toLegacyPrompt(ConnectionHostKeyPrompt prompt) {
  return SshHostKeyPromptRequest(
    connectionId: prompt.connectionId,
    connectionName: prompt.connectionName,
    host: prompt.host,
    port: prompt.port,
    username: prompt.username,
    algorithm: prompt.algorithm,
    fingerprint: prompt.fingerprint,
  );
}
