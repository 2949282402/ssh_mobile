// System Admin Module 测试替身。
//
// 这些替身只模拟 Port 的生命周期和返回值，不建立真实 SSH、SFTP 或存储
// 连接，用来验证模块注册、管理会话关闭以及命令取消边界。

import 'dart:async';

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

  void replaceConnections(List<ConnectionConfig> value) {
    connections = List<ConnectionConfig>.unmodifiable(value);
    notifyListeners();
  }
}

ConnectionConfig systemAdminTestConnection(
  String id, {
  String? host,
  String username = 'root',
}) => ConnectionConfig(
  id: id,
  name: id,
  host: host ?? '$id.example.test',
  username: username,
);

SshTargetBinding systemAdminTestTarget(
  String id, {
  String? host,
  String username = 'root',
}) => SshTargetBinding.fromConfig(
  systemAdminTestConnection(id, host: host, username: username),
);

typedef FakeSystemAdminCommandResponder =
    FutureOr<RemoteCommandResult> Function(SystemAdminCommand command);

/// 可记录目标、命令、取消和释放的管理 Lease 替身。
final class FakeSystemAdminSshLease implements SystemAdminSshLeasePort {
  FakeSystemAdminSshLease({
    required this.targetBinding,
    this.stdout = '0',
    this.exitCode = 0,
    this.responder,
  });

  @override
  final SshTargetBinding targetBinding;
  final String stdout;
  final int? exitCode;
  FakeSystemAdminCommandResponder? responder;
  final List<SystemAdminCommand> commands = <SystemAdminCommand>[];
  int runCount = 0;
  int cancelCount = 0;
  int releaseCount = 0;

  @override
  bool isReleased = false;

  @override
  Future<RemoteCommandResult> run(
    SystemAdminCommand command, {
    required Duration timeout,
  }) async {
    if (isReleased) throw StateError('Fake lease is released');
    runCount++;
    commands.add(command);
    final handler = responder;
    if (handler != null) return handler(command);
    return RemoteCommandResult(exitCode: exitCode, stdout: stdout, stderr: '');
  }

  @override
  void cancelActiveCommands() {
    cancelCount++;
  }

  @override
  Future<void> release() async {
    releaseCount++;
    isReleased = true;
  }
}

/// 管理 SSH 连接 Port 的可观察替身。
final class FakeSystemAdminSshPort implements SystemAdminSshPort {
  FakeSystemAdminSshPort([this.lease]);

  final FakeSystemAdminSshLease? lease;
  FutureOr<SystemAdminSshLeasePort> Function(SshTargetBinding target)?
  acquireOverride;
  final List<SshTargetBinding> acquiredTargets = <SshTargetBinding>[];
  final List<SshHostKeyConfirmation?> acquiredHostKeyConfirmations =
      <SshHostKeyConfirmation?>[];
  int acquireCount = 0;

  @override
  Future<SystemAdminSshLeasePort> acquire(
    SshTargetBinding target, {
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    acquireCount++;
    acquiredTargets.add(target);
    acquiredHostKeyConfirmations.add(onUnknownHostKey);
    final handler = acquireOverride;
    if (handler != null) return handler(target);
    final result = lease;
    if (result == null) throw StateError('No fake lease configured');
    return result;
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
