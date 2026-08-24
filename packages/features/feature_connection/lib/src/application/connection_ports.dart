import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/widgets.dart';

/// 用户确认未知 SSH Host Key 时使用的 Feature 级提示数据。
///
/// 这里不暴露 App 层的对话框或 SSH 实现，UI 适配器可以将它转换为平台
/// 对话框需要的模型；指纹在确认前后都必须保持原值，不能由展示层重算。
final class ConnectionHostKeyPrompt {
  const ConnectionHostKeyPrompt({
    required this.connectionId,
    required this.connectionName,
    required this.host,
    required this.port,
    required this.username,
    required this.algorithm,
    required this.fingerprint,
  });

  final String connectionId;
  final String connectionName;
  final String host;
  final int port;
  final String username;
  final String algorithm;
  final String fingerprint;
}

/// Host Key 确认回调的公开契约。
typedef ConnectionHostKeyConfirmation =
    FutureOr<bool> Function(ConnectionHostKeyPrompt prompt);

/// 连接验证成功后返回的 Host Key 元数据。
final class ConnectionVerificationResult {
  const ConnectionVerificationResult({
    this.algorithm,
    this.fingerprint,
    this.trustedAt,
  });

  final String? algorithm;
  final String? fingerprint;
  final DateTime? trustedAt;
}

/// 由 App/Infrastructure 注入的 SSH 登录验证能力。
///
/// Feature 只负责验证流程状态和保存编排，不直接依赖具体 SSH 客户端、
/// Socket、超时实现或 Host Key 策略实现。实现只能返回候选 Host Key 元数据，
/// 不得自行持久化；Feature 会在配置、Host Key 和凭据的统一提交阶段写入。
abstract interface class ConnectionVerificationPort {
  Future<ConnectionVerificationResult> verify(
    ConnectionConfig config, {
    required String? password,
    required String? privateKey,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  });
}

/// 由 App Scope 注入的连接运行时能力。
///
/// 这些操作可能触发 SSH/SFTP/监控连接和磁盘缓存清理，Feature 只拥有
/// 调用关系，不拥有底层资源，资源释放仍由 AppRuntime 负责。
abstract interface class ConnectionRuntimePort {
  String? get errorMessage;

  Future<int> activeWindowCount(String connectionId);

  Future<void> disconnectSessionsForConnection(String connectionId);

  Future<void> cleanupConnectionResources(String connectionId);

  Future<String?> openTerminalSession(
    String connectionId,
    String windowName, {
    ConnectionHostKeyConfirmation? onUnknownHostKey,
  });
}

/// 连接页面依赖的展示层桥接能力。
///
/// 该契约让 Feature 不需要知道 App 的日志实现和 Host Key 对话框；测试时
/// 可以注入纯内存实现，生产环境由 App 组合根连接到现有 UI 组件。
abstract interface class ConnectionUiAdapter {
  Future<bool> confirmHostKey(
    BuildContext context,
    ConnectionHostKeyPrompt prompt,
  );

  void logSaveFailure({
    required Object error,
    required StackTrace stackTrace,
    required ConnectionConfig? config,
  });
}
