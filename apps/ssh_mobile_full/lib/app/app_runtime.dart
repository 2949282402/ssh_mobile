import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_developer/feature_developer.dart' as feature_developer;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_webview/feature_webview.dart' as feature_webview;
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_core/ssh_core.dart';

import 'lan_share_feature_adapters.dart';
import 'ai_external_capability_adapters.dart';
import 'ai_feature_adapters.dart';
import 'mcp_feature_adapters.dart';
import 'playbook_feature_adapters.dart';
import 'rag_feature_adapters.dart';
import 'webview_feature_adapters.dart';
import 'developer_feature_adapters.dart';
import '../services/app_bootstrap_coordinator.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';

/// 应用生命周期运行时，持有 App Scope 的基础设施和长期服务。
///
/// Runtime 只持有 App Scope 的基础设施与 Feature Module，不持有跨模块的
/// 统一数据库门面。UI 只能通过构造注入或 Provider 读取这些实例，不能
/// 自行创建同类全局对象。
final class AppRuntime implements Disposable {
  /// 创建由 AppRuntime 独占的应用级资源集合。
  AppRuntime({
    required this.appLogService,
    required this.appSettings,
    required this.connectionDatabase,
    required this.connectionRepository,
    required this.credentialRepository,
    required this.hostKeyRepository,
    required this.networkRuntime,
    required this.realtimeClient,
    required this.bootstrapCoordinator,
    required this.shortcutCommandService,
    required this.sshSessionManager,
    required this.sshService,
    required this.sftpService,
    required this.monitoringModule,
    required this.monitoringService,
    required this.playbookModule,
    required this.playbookSettingsAdapter,
    required this.playbookConnectionCatalogAdapter,
    required this.ragModule,
    required this.ragSettingsAdapter,
    required this.mcpModule,
    required this.mcpSettingsAdapter,
    required this.lanShareModule,
    required this.lanShareSettingsAdapter,
    required this.webViewService,
    required this.webViewSettingsAdapter,
    required this.developerLogAdapter,
    required this.developerSettingsAdapter,
    required this.developerDiagnosticsAdapter,
    required this.aiModule,
    required this.aiStorageAdapter,
    required this.aiSettingsAdapter,
    required this.aiSshAdapter,
    required this.aiSftpAdapter,
    required this.aiMonitoringAdapter,
    required this.aiClientSystemAdapter,
    required this.aiHealthAdapter,
    required this.aiWebViewAdapter,
    required this.aiServerCatalogAdapter,
    required this.aiServerDiagnosticsAdapter,
    required this.aiChatRuntimeFactory,
  });

  /// App Scope 唯一的日志实现；当前由 AppLogService 适配 Core Contract。
  final AppLogService appLogService;

  /// 供新模块通过 Core Contract 获取同一个日志 Owner。
  AppLogger get logger => appLogService;

  // TODO(refactor-step-06): 替换为配置模块的公共设置契约。
  final AppSettings appSettings;

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

  /// App Scope Realtime SDK owner; its backend borrows the NetworkRuntime handle.
  final RealtimeClient realtimeClient;

  /// 启动协调器属于 App Shell，负责首帧前后的核心初始化状态。
  final AppBootstrapCoordinator bootstrapCoordinator;

  // TODO(refactor-step-18): 将快捷键配置迁移到 settings 模块。
  final ShortcutCommandService shortcutCommandService;

  // 旧 API 兼容视图；实际 App Scope Owner 由下方的 SshSessionManager 字段表达。
  final SshService sshService;

  /// App Scope 唯一 SSH Manager；旧 [sshService] 是同一实例的兼容类型视图。
  final SshSessionManager sshSessionManager;

  // TODO(refactor-step-10): 替换为 sftp feature 的公共运行时契约。
  final SftpService sftpService;

  /// Monitoring Module 的 App Scope Owner；Module 不在激活时默认轮询。
  final monitoring.MonitoringModule monitoringModule;

  /// Monitoring Module 创建的唯一监控服务实例。
  final monitoring.MonitoringService monitoringService;

  /// Playbook Module 的唯一 App Scope Owner。
  final feature_playbook.PlaybookModule playbookModule;

  /// 供 Playbook Route Scope 使用的设置适配器，不拥有 AppSettings。
  final AppPlaybookSettingsAdapter playbookSettingsAdapter;

  /// 供 Playbook Route Scope 使用的连接目录适配器，不拥有底层 Repository。
  final AppPlaybookConnectionCatalogAdapter playbookConnectionCatalogAdapter;

  /// 旧 Runtime API 兼容视图；实际 Service Owner 是 [playbookModule]。
  feature_playbook.PlaybookService get playbookService =>
      playbookModule.service;

  /// RAG Module 的唯一 App Scope Owner。
  final feature_rag.RagModule ragModule;

  /// 供 RAG Route Scope 使用的设置适配器，不拥有 AppSettings 或安全存储。
  final AppRagSettingsAdapter ragSettingsAdapter;

  /// 旧 Runtime API 兼容视图；实际 Service Owner 是 [ragModule]。
  feature_rag.RagService get ragService => ragModule.service;

  /// MCP Module 的唯一 App Scope Owner；Module 独占 mcp.db 和 Server。
  final feature_mcp.McpModule mcpModule;

  /// MCP Module 使用的设置适配器，不拥有 AppSettings。
  final AppMcpSettingsAdapter mcpSettingsAdapter;

  /// 旧 Runtime API 兼容视图；实际 Owner 是 [mcpModule]。
  feature_mcp.McpServerController get mcpServerController => mcpModule.service;

  /// LAN Share Module 的唯一 App Scope Owner。
  final feature_lan_share.LanShareModule lanShareModule;

  /// 由 Runtime 持有的设置适配器；Module 只消费其 Port。
  final AppLanShareSettingsAdapter lanShareSettingsAdapter;

  /// WebView Feature 的 App Scope 会话服务；按聊天 ID 管理 Controller。
  final feature_webview.ClientWebViewService webViewService;

  /// WebView 页面消费的设置 Port，不拥有底层 AppSettings。
  final AppWebViewSettingsAdapter webViewSettingsAdapter;

  /// Developer Feature 的 App Shell Port 适配器；不把旧服务类型泄漏给页面。
  final AppDeveloperLogAdapter developerLogAdapter;
  final AppDeveloperSettingsAdapter developerSettingsAdapter;
  final AppDeveloperDiagnosticsAdapter developerDiagnosticsAdapter;

  /// 供 Provider 注册的开发者日志能力。
  feature_developer.DeveloperLogPort get developerLogPort =>
      developerLogAdapter;

  /// 供 Provider 注册的开发者设置能力。
  feature_developer.DeveloperSettingsPort get developerSettingsPort =>
      developerSettingsAdapter;

  /// 供 Provider 注册的开发者诊断能力。
  feature_developer.DeveloperDiagnosticsPort get developerDiagnosticsPort =>
      developerDiagnosticsAdapter;

  /// AI Module 的唯一 App Scope Owner；ai.db 只在首次 AI 使用时打开。
  final feature_ai.AiModule aiModule;

  /// AI Route 使用的 App Shell Port 适配器；它们不拥有底层 App 资源。
  final AppAiStorageAdapter aiStorageAdapter;
  final AppAiSettingsAdapter aiSettingsAdapter;
  final AppAiSshAdapter aiSshAdapter;
  final AppAiSftpAdapter aiSftpAdapter;
  final AppAiMonitoringAdapter aiMonitoringAdapter;
  final AppAiClientSystemAdapter aiClientSystemAdapter;
  final AppAiHealthAdapter aiHealthAdapter;
  final AppAiWebViewAdapter aiWebViewAdapter;
  final AppAiServerCatalogAdapter aiServerCatalogAdapter;
  final AppAiServerDiagnosticsAdapter aiServerDiagnosticsAdapter;
  final feature_ai.AiChatRuntimeFactory aiChatRuntimeFactory;

  /// 旧 API 兼容外观；实际接收器 Owner 是 [lanShareModule]。
  feature_lan_share.LanReceiverCoordinator get lanReceiverCoordinator =>
      lanShareModule.coordinator;

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
      await mcpModule.dispose();
      _debugAssertModuleDisposed(mcpModule);
      mcpSettingsAdapter.dispose();
    });
    await attempt(() async {
      await lanShareModule.dispose();
      _debugAssertModuleDisposed(lanShareModule);
    });
    await attempt(lanShareSettingsAdapter.dispose);
    await attempt(() async {
      await aiStorageAdapter.shutdown();
      aiStorageAdapter.dispose();
    });
    await attempt(() async {
      await aiModule.dispose();
      _debugAssertModuleDisposed(aiModule);
    });
    // AI 停止后再关闭 WebView，确保运行中的客户端工具不会继续访问
    // 已经释放的 Controller；设置适配器先解除 AppSettings 监听。
    await attempt(webViewSettingsAdapter.dispose);
    await attempt(webViewService.dispose);
    // 先解除 Developer Feature 对底层服务的观察，再关闭被观察资源。
    await attempt(developerDiagnosticsAdapter.dispose);
    developerDiagnosticsAdapter.debugAssertReleased();
    await attempt(developerLogAdapter.dispose);
    await attempt(developerSettingsAdapter.dispose);
    await attempt(aiSettingsAdapter.dispose);
    await attempt(() async {
      await playbookModule.dispose();
      _debugAssertModuleDisposed(playbookModule);
    });
    await attempt(playbookSettingsAdapter.dispose);
    await attempt(playbookConnectionCatalogAdapter.dispose);

    // 等待启动中的 Storage 初始化完成，再关闭数据库，避免异步初始化在
    // shutdown 之后重新打开数据库或继续触发通知。
    await attempt(() async {
      try {
        await bootstrapCoordinator.ensureBootstrap();
      } finally {
        bootstrapCoordinator.dispose();
      }
    });

    // SSH Manager 统一关闭共享 Session Pool、Runtime 和旧 API 兼容资源。
    await attempt(sshSessionManager.close);
    assert(() {
      if (sshService.activeSubscriptionCount != 0 ||
          sshService.activeTimerCount != 0 ||
          sshService.leaseCount != 0) {
        throw StateError('SSH resources were not released.');
      }
      return true;
    }());

    // 当前 SFTP 实现仍直接持有 SSH 客户端，这里作为网络资源组释放。
    await attempt(sftpService.dispose);
    // Realtime sessions/backend subscriptions must stop before native Runtime.
    await attempt(realtimeClient.dispose);
    // SSH/SFTP 停止后再关闭网络 Runtime，避免仍有会话向 native handle 发命令。
    await attempt(networkRuntime.dispose);
    assert(() {
      if (networkRuntime.diagnostics.nativeHandles != 0) {
        throw StateError('Network native handles were not released.');
      }
      return true;
    }());

    // 业务 Module 的 Timer/监听器先释放，再关闭其共享数据库。
    await attempt(() async {
      await monitoringModule.dispose();
      _debugAssertModuleDisposed(monitoringModule);
      assert(!monitoringService.isRunning);
    });
    await attempt(() async {
      await ragModule.dispose();
      _debugAssertModuleDisposed(ragModule);
    });
    await attempt(ragSettingsAdapter.dispose);
    await attempt(shortcutCommandService.dispose);
    await attempt(appSettings.dispose);
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
    assert(appLogService.activeTimerCount == 0);

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace ?? StackTrace.current);
    }
  }

  /// Debug 模式下确认 Module 的生命周期 Owner 已完成资源释放。
  static void _debugAssertModuleDisposed(AppModule module) {
    assert(() {
      if (module.state != ModuleState.disposed) {
        throw StateError('Module ${module.id} was not disposed.');
      }
      return true;
    }());
  }
}
