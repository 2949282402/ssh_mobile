import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:network_transport/network_transport.dart';

import '../features/ai_chat/services/ai_chat_runtime_factory.dart';
import '../features/lan_share/services/lan_receiver_coordinator.dart';
import '../services/app_bootstrap_coordinator.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/display_mode_service.dart';
import '../services/mcp/mcp_server_controller.dart';
import '../services/performance_monitor_service.dart';
import '../services/playbook_service.dart';
import '../services/rag_service.dart';
import '../services/sftp_service.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import 'app_runtime.dart';

/// App Scope 的唯一组装入口，负责创建并连接应用级服务。
///
/// 该工厂只做依赖装配，不把路由级 ViewModel 放进 Runtime；页面状态仍
/// 由 Provider 或 Route Scope 管理。初始化仍保持原来的非阻塞策略，避免
/// 为建立 Composition Root 而改变首帧和业务行为。
final class AppRuntimeFactory {
  AppRuntimeFactory._();

  /// 创建应用级 Runtime，并启动原有的轻量异步初始化任务。
  ///
  /// Connection 依赖参数只用于测试注入；生产入口不传参时始终创建一组
  /// Runtime 独占的数据库和 Repository。
  static Future<AppRuntime> create({
    AppLogService? appLogService,
    connection_core.ConnectionDatabase? connectionDatabase,
    connection_core.ConnectionRepository? connectionRepository,
    connection_core.CredentialRepository? credentialRepository,
    connection_core.HostKeyRepository? hostKeyRepository,
    NetworkRuntime? networkRuntime,
  }) async {
    final logger = appLogService ?? AppLogService();
    logger.install();
    logger.info('Application bootstrap started');

    final runtimeConnectionDatabase =
        connectionDatabase ?? connection_core.ConnectionDatabase();
    final runtimeConnectionRepository =
        connectionRepository ??
        connection_core.DriftConnectionRepository(
          database: runtimeConnectionDatabase,
        );
    final runtimeCredentialRepository =
        credentialRepository ?? connection_core.SecureCredentialRepository();
    final runtimeHostKeyRepository = _resolveHostKeyRepository(
      supplied: hostKeyRepository,
      connectionRepository: runtimeConnectionRepository,
    );
    final runtimeNetworkRuntime = networkRuntime ?? NetworkRuntimeImpl();
    unawaited(
      runtimeConnectionRepository.initialize().catchError((error, stackTrace) {
        logger.error(
          'Connection repository initialization failed',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );

    // 这些任务原本由 main 并发发起，继续保持不阻塞 runApp 的行为。
    unawaited(SharedPreferences.getInstance());
    unawaited(DisplayModeService.enableHighRefreshRate());

    final appSettings = AppSettings();
    final storageService = StorageService();
    final bootstrapCoordinator = AppBootstrapCoordinator(
      appSettings: appSettings,
      storageService: storageService,
    );
    unawaited(bootstrapCoordinator.ensureBootstrap());
    storageService.registerOnImportCallback(appSettings.init);

    final shortcutCommandService = ShortcutCommandService()..init();
    storageService.registerOnImportCallback(shortcutCommandService.init);

    final sshService = SshService(storageService, appSettings: appSettings);
    unawaited(
      sshService.ensureInitialized().catchError((error, stackTrace) {
        logger.error(
          'SSH service initialization failed',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );

    final sftpService = SftpService(storageService);
    final performanceMonitorService = PerformanceMonitorService(
      sshService,
      storageService,
      appSettings: appSettings,
    );
    final playbookService = PlaybookService(
      storageService: storageService,
      sshService: sshService,
    );
    final ragService = RagService(storageService: storageService);
    storageService.registerOnImportCallback(() => ragService.init(force: true));

    final mcpServerController = McpServerController(
      appSettings: appSettings,
      activityRepository: storageService,
      toolServiceFactory: () => AiChatRuntimeFactory(
        storageService: storageService,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitorService,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      ).createToolService(),
    );
    final lanReceiverCoordinator = LanReceiverCoordinator(
      storageService: storageService,
      appSettings: appSettings,
    );

    return AppRuntime(
      appLogService: logger,
      appSettings: appSettings,
      storageService: storageService,
      connectionDatabase: runtimeConnectionDatabase,
      connectionRepository: runtimeConnectionRepository,
      credentialRepository: runtimeCredentialRepository,
      hostKeyRepository: runtimeHostKeyRepository,
      networkRuntime: runtimeNetworkRuntime,
      bootstrapCoordinator: bootstrapCoordinator,
      shortcutCommandService: shortcutCommandService,
      sshService: sshService,
      sftpService: sftpService,
      performanceMonitorService: performanceMonitorService,
      playbookService: playbookService,
      ragService: ragService,
      mcpServerController: mcpServerController,
      lanReceiverCoordinator: lanReceiverCoordinator,
    );
  }

  /// 从显式注入或同一 Connection Repository 派生 Host Key 契约。
  static connection_core.HostKeyRepository _resolveHostKeyRepository({
    required connection_core.HostKeyRepository? supplied,
    required connection_core.ConnectionRepository connectionRepository,
  }) {
    final explicit = supplied;
    if (explicit != null) return explicit;
    final derived = connectionRepository;
    if (derived is connection_core.HostKeyRepository) {
      return derived as connection_core.HostKeyRepository;
    }
    throw ArgumentError(
      'A HostKeyRepository is required with a custom ConnectionRepository.',
    );
  }
}
