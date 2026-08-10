// System Admin Module 测试替身。
//
// 这些替身只模拟 Port 的生命周期和返回值，不建立真实 SSH、SFTP 或存储
// 连接，用来验证模块注册、管理会话关闭以及命令取消边界。

import 'package:connection_core/connection_core.dart';
import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter/foundation.dart';
import 'package:ssh_core/ssh_core.dart';

/// Minimal in-memory connection catalog for Route ViewModel tests.
final class FakeSystemAdminConnectionCatalog extends ChangeNotifier
    implements SystemAdminConnectionCatalogPort {
  @override
  bool isInitialized = true;

  @override
  List<ConnectionConfig> connections = const [];

  @override
  ConnectionConfig? connectionById(String id) =>
      connections.where((item) => item.id == id).firstOrNull;

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}
}

/// 可记录命令、取消和关闭的管理会话替身。
final class FakeSystemAdminSshSession implements SystemAdminSshSessionPort {
  FakeSystemAdminSshSession({this.stdout = '0', this.exitCode = 0});

  final String stdout;
  final int? exitCode;
  int runCount = 0;
  int cancelCount = 0;
  bool isClosed = false;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    runCount++;
    return RemoteCommandResult(exitCode: exitCode, stdout: stdout, stderr: '');
  }

  @override
  void cancelActiveCommands() {
    cancelCount++;
  }

  @override
  void close() {
    isClosed = true;
  }
}

/// 管理 SSH 连接 Port 的可观察替身。
final class FakeSystemAdminSshPort implements SystemAdminSshPort {
  FakeSystemAdminSshPort(this.session);

  final FakeSystemAdminSshSession session;
  int connectCount = 0;

  @override
  Future<SystemAdminSshSessionPort> connect(
    String connectionId, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    connectCount++;
    return session;
  }
}

/// 记录模块日志调用的替身。
final class FakeSystemAdminLogger implements SystemAdminLoggerPort {
  final List<String> infos = [];
  final List<String> warnings = [];
  final List<String> errors = [];

  @override
  void info(String message, {String? details}) => infos.add(message);

  @override
  void warning(String message, {String? details}) => warnings.add(message);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) => errors.add(message);
}

extension<E> on Iterable<E> {
  E? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
