import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:network_transport/network_transport.dart';

import '../features/lan_share/services/lan_receiver_coordinator.dart';
import '../services/app_bootstrap_coordinator.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/mcp/mcp_server_controller.dart';
import '../services/performance_monitor_service.dart';
import '../services/playbook_service.dart';
import '../services/rag_service.dart';
import '../services/sftp_service.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';

/// 应用生命周期运行时，持有 App Scope 的基础设施和长期服务。
///
/// 这里暂时保留旧 Service 类型，是为了先建立唯一 Owner，再在后续
/// Step 中逐个替换为 Core/Infrastructure 的公共契约。UI 只能通过构造
/// 注入或 Provider 读取这些实例，不能自行创建同类全局对象。
final class AppRuntime implements Disposable {
  /// 创建由 AppRuntime 独占的应用级资源集合。
  AppRuntime({
    required this.appLogService,
    required this.appSettings,
    required this.storageService,
    required this.connectionDatabase,
    required this.connectionRepository,
    required this.credentialRepository,
    required this.hostKeyRepository,
    required this.networkRuntime,
    required this.bootstrapCoordinator,
    required this.shortcutCommandService,
    required this.sshService,
    required this.sftpService,
    required this.performanceMonitorService,
    required this.playbookService,
    required this.ragService,
    required this.mcpServerController,
    required this.lanReceiverCoordinator,
  });

  /// App Scope 唯一的日志实现；当前由 AppLogService 适配 Core Contract。
  final AppLogService appLogService;

  /// 供新模块通过 Core Contract 获取同一个日志 Owner。
  AppLogger get logger => appLogService;

  // TODO(refactor-step-06): 替换为配置模块的公共设置契约。
  final AppSettings appSettings;

  // TODO(refactor-step-22): 将剩余跨 Feature 数据库逐步从旧 StorageService
  // facade 拆到各自模块；Connection 数据库已在本 Runtime 中独立归属。
  final StorageService storageService;

  /// Connection 模块独立数据库，由 Runtime 创建并在数据库阶段关闭。
  final connection_core.ConnectionDatabase connectionDatabase;

  /// Connection 结构 Repository 的 App Scope 唯一实例。
  final connection_core.ConnectionRepository connectionRepository;

  /// Connection 凭据 Repository 的 App Scope 唯一实例。
  final connection_core.CredentialRepository credentialRepository;

  /// Host Key 信任 Repository 的 App Scope 唯一实例。
  final connection_core.HostKeyRepository hostKeyRepository;

  /// App Scope 唯一的网络运行时；其 native handle 只按 Capability 延迟创建。
  final NetworkRuntime networkRuntime;

  /// 启动协调器属于 App Shell，负责首帧前后的核心初始化状态。
  final AppBootstrapCoordinator bootstrapCoordinator;

  // TODO(refactor-step-18): 将快捷键配置迁移到 settings 模块。
  final ShortcutCommandService shortcutCommandService;

  // TODO(refactor-step-08): 替换为 ssh_core 的 SshSessionManager。
  final SshService sshService;

  // TODO(refactor-step-10): 替换为 sftp feature 的公共运行时契约。
  final SftpService sftpService;

  // TODO(refactor-step-11): 将监控运行时迁移到 performance 模块。
  final PerformanceMonitorService performanceMonitorService;

  // TODO(refactor-step-16): 将 Playbook 服务迁移到 playbook 模块。
  final PlaybookService playbookService;

  // TODO(refactor-step-16): 将 RAG 服务迁移到 rag 模块。
  final RagService ragService;

  // TODO(refactor-step-20): 将 MCP Server 运行时迁移到 mcp_console 模块。
  final McpServerController mcpServerController;

  // TODO(refactor-step-13): 将 LAN 接收器迁移到 lan_share 模块的 App Scope。
  final LanReceiverCoordinator lanReceiverCoordinator;

  Future<void>? _disposeFuture;
  bool _disposed = false;

  /// 当前 Runtime 是否已经开始释放资源。
  bool get isDisposed => _disposed;

  /// 按“模块 → SSH → 网络 → 数据库/Repository → Logger”顺序释放资源。
  ///
  /// 每个资源组即使释放失败也会继续执行后续释放，最后重新抛出第一个
  /// 错误，避免一个异常导致其他连接、Timer 或数据库句柄永久泄漏。
  @override
  Future<void> dispose() {
    final inFlight = _disposeFuture;
    if (inFlight != null) return inFlight;

    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    // App Scope 模块先停止对外提供服务，避免释放基础设施时仍有新请求进入。
    await attempt(() async {
      try {
        await mcpServerController.stop();
      } finally {
        mcpServerController.dispose();
      }
    });
    await attempt(lanReceiverCoordinator.dispose);

    // 等待启动中的 Storage 初始化完成，再关闭数据库，避免异步初始化在
    // shutdown 之后重新打开数据库或继续触发通知。
    await attempt(() async {
      try {
        await bootstrapCoordinator.ensureBootstrap();
      } finally {
        bootstrapCoordinator.dispose();
      }
    });

    // SSH 会话依赖底层网络和存储，必须先于这些资源关闭。
    await attempt(() async {
      try {
        await sshService.ensureInitialized();
      } finally {
        sshService.dispose();
      }
    });

    // 当前 SFTP 实现仍直接持有 SSH 客户端，这里作为网络资源组释放。
    await attempt(sftpService.dispose);
    // SSH/SFTP 停止后再关闭网络 Runtime，避免仍有会话向 native handle 发命令。
    await attempt(networkRuntime.dispose);

    // 业务服务的 Timer/监听器先释放，再关闭其共享数据库。
    await attempt(performanceMonitorService.dispose);
    await attempt(playbookService.dispose);
    await attempt(ragService.dispose);
    await attempt(shortcutCommandService.dispose);
    await attempt(appSettings.dispose);
    await attempt(() async {
      try {
        await storageService.shutdown();
      } finally {
        storageService.dispose();
      }
    });
    await attempt(() async {
      try {
        // 等待异步首载完成，避免关闭数据库后初始化任务再次访问句柄。
        await connectionRepository.initialize();
      } finally {
        await connectionDatabase.dispose();
      }
    });

    // Logger 必须最后释放，因为上面的资源可能仍需记录关闭失败。
    await attempt(appLogService.dispose);

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace ?? StackTrace.current);
    }
  }
}
