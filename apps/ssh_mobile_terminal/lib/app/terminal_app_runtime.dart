// Terminal-only App 的 App Scope 运行时。
//
// Runtime 只持有该编译切片所需的 Connection、Network、SSH 和日志资源；
// TerminalModule 独占 terminal.db，任何未选择的 Feature 都不会被创建。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/foundation.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';

import 'terminal_app_ports.dart';
import 'terminal_only_capability.dart';

/// Terminal-only App 的 App Scope Owner。
final class TerminalAppRuntime implements Disposable {
  TerminalAppRuntime._({
    required this.logger,
    required this.connectionDatabase,
    required this.connectionRepository,
    required this.credentialRepository,
    required this.hostKeyRepository,
    required this.networkRuntime,
    required this.sshSessionManager,
    required this.terminalCapability,
    required this.terminalModule,
    required this.settings,
    required this.shortcuts,
    required this.connections,
    required this.terminalLogger,
  });

  /// App Scope Logger。
  final AppLoggerImpl logger;

  /// Connection Core 数据库 Owner。
  final ConnectionDatabase? connectionDatabase;

  /// Connection 结构 Repository。
  final ConnectionRepository? connectionRepository;

  /// Secure Storage 凭据 Repository。
  final CredentialRepository? credentialRepository;

  /// Host Key 元数据 Repository。
  final HostKeyRepository? hostKeyRepository;

  /// App Scope 网络运行时。
  final NetworkRuntime networkRuntime;

  /// App Scope SSH Manager。
  final SshSessionManager sshSessionManager;

  /// Terminal-only 的 SSH 能力实现。
  final TerminalOnlyCapability terminalCapability;

  /// Terminal Module；唯一拥有 terminal.db 的对象。
  final TerminalModule terminalModule;

  /// Terminal 页面设置 Port。
  final TerminalOnlySettings settings;

  /// Terminal 页面快捷命令 Port。
  final TerminalOnlyShortcuts shortcuts;

  /// Terminal 页面连接 Port。
  final TerminalOnlyConnections connections;

  /// Terminal 页面日志 Port。
  final TerminalOnlyLogger terminalLogger;

  Future<void>? _disposeFuture;

  /// 为 Runtime 生命周期测试创建不打开平台数据库的实例。
  @visibleForTesting
  TerminalAppRuntime.forTesting({
    required this.logger,
    required this.networkRuntime,
    required this.sshSessionManager,
    required this.terminalCapability,
    required this.terminalModule,
    required this.settings,
    required this.shortcuts,
    required this.connections,
    required this.terminalLogger,
    this.connectionDatabase,
    this.connectionRepository,
    this.credentialRepository,
    this.hostKeyRepository,
  });

  /// 创建并初始化 Terminal-only App 的最小资源集合。
  static Future<TerminalAppRuntime> create() async {
    final logger = AppLoggerImpl();
    final connectionDatabase = ConnectionDatabase();
    final connectionRepository = DriftConnectionRepository(
      database: connectionDatabase,
    );
    final credentialRepository = SecureCredentialRepository();
    final networkRuntime = NetworkRuntimeImpl();
    final terminalCapability = TerminalOnlyCapability();
    final sshSessionManager = SshSessionManagerImpl(
      runtime: DesktopSshRuntime(),
      terminalCapability: terminalCapability,
    );
    final terminalModule = TerminalModule();
    final settings = TerminalOnlySettings();
    final shortcuts = TerminalOnlyShortcuts();
    final connections = TerminalOnlyConnections(
      repository: connectionRepository,
      terminal: terminalCapability,
    );
    final terminalLogger = TerminalOnlyLogger(logger);

    try {
      await connectionRepository.initialize();
      await sshSessionManager.ensureInitialized();
      await terminalModule.register(
        ModuleContext.fromMap({SshSessionManager: sshSessionManager}),
      );
      await terminalModule.initialize();
      await terminalModule.activate();
      return TerminalAppRuntime._(
        logger: logger,
        connectionDatabase: connectionDatabase,
        connectionRepository: connectionRepository,
        credentialRepository: credentialRepository,
        hostKeyRepository: connectionRepository as HostKeyRepository,
        networkRuntime: networkRuntime,
        sshSessionManager: sshSessionManager,
        terminalCapability: terminalCapability,
        terminalModule: terminalModule,
        settings: settings,
        shortcuts: shortcuts,
        connections: connections,
        terminalLogger: terminalLogger,
      );
    } catch (_) {
      await terminalModule.dispose();
      await terminalCapability.close();
      await sshSessionManager.close();
      await networkRuntime.dispose();
      await connectionDatabase.dispose();
      settings.dispose();
      shortcuts.dispose();
      await logger.dispose();
      rethrow;
    }
  }

  /// 以 Module → SSH → Network → Database → Port → Logger 顺序释放资源。
  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    await terminalModule.dispose();
    await terminalCapability.close();
    await sshSessionManager.close();
    await networkRuntime.dispose();
    await connectionDatabase?.dispose();
    settings.dispose();
    shortcuts.dispose();
    await logger.dispose();
  }
}
