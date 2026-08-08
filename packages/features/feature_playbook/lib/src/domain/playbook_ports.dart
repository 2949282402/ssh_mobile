// Playbook Feature 的跨层 Port。
//
// 这些接口隔离 App Shell 的旧 Storage、SSH、日志和安全实现，使剧本执行器
// 可以在没有真实网络或平台数据库的测试中运行，也避免 Feature 反向依赖 App。

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

import '../features/playbook/models/playbook.dart';

/// Playbook 页面使用的语言。
enum PlaybookLanguage { zh, en }

/// AI 工具和聊天运行时使用的 Playbook 公共能力。
///
/// 该接口只暴露跨 Feature 所需的状态查询和执行入口。执行入口接收
/// [SshTargetBinding]，确保审批绑定仍然来自不可变的目标快照；具体 Service
/// 可以在迁移期间由新 Package 或旧 App 适配层实现。
abstract interface class PlaybookAutomationPort implements Listenable {
  String? get pendingDiagnosticPrompt;

  set pendingDiagnosticPrompt(String? value);

  List<Playbook> get playbooks;

  Playbook? get activePlaybook;

  int get currentStepIndex;

  bool get isRunning;

  bool get isPaused;

  Future<void> startExecution(String playbookId, String connectionId);

  Future<bool> startApprovedExecutionForBinding({
    required Playbook playbook,
    required String actionFingerprint,
    required SshTargetBinding connectionTarget,
  });
}

/// 设置和语言变化的最小能力。
abstract interface class PlaybookSettingsPort implements Listenable {
  PlaybookLanguage get language;

  bool get isEnglish => language == PlaybookLanguage.en;
}

/// Playbook 只读连接目录；它不拥有连接或凭据。
abstract interface class PlaybookConnectionCatalogPort implements Listenable {
  bool get isInitialized;

  List<ConnectionConfig> get connections;

  ConnectionConfig? connectionById(String id);
}

/// Playbook Service 的结构化日志能力。
abstract interface class PlaybookLoggerPort {
  void info(String message, {String? details});

  void warning(String message, {String? details});

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}

/// 数据库敏感文本的加解密能力。
abstract interface class PlaybookDataProtectionPort {
  Future<String> encryptString(String plaintext);

  Future<String> decryptString(String value);

  bool isEncrypted(String value);
}

/// App Shell 提供的一次性 SSH 命令能力。
///
/// 绑定执行必须使用不可变目标快照；Service 不允许在每个步骤重新从 UI
/// 读取连接配置，否则编辑服务器后可能把已审批的剧本重定向到别的目标。
abstract interface class PlaybookSshPort {
  Future<RemoteCommandResult> runCommand({
    required String connectionId,
    required String command,
    Duration timeout,
  });

  Future<RemoteCommandResult> runCommandForBinding({
    required SshTargetBinding binding,
    required String command,
    Duration timeout,
  });
}
