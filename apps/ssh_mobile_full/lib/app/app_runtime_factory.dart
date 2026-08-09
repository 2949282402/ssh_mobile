import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_webview/feature_webview.dart' as feature_webview;
import 'package:network_transport/network_transport.dart';

import '../core/services/data_protection_service.dart';
import '../services/app_bootstrap_coordinator.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/display_mode_service.dart';
import '../services/network/network_identity_service.dart';
import '../services/performance_monitor_service.dart';
import '../services/sftp_service.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import 'app_runtime.dart';
import 'ai_external_capability_adapters.dart';
import 'ai_feature_adapters.dart';
import 'developer_feature_adapters.dart';
import 'lan_share_feature_adapters.dart';
import 'mcp_feature_adapters.dart';
import 'monitoring_feature_adapters.dart';
import 'playbook_feature_adapters.dart';
import 'rag_feature_adapters.dart';
import 'terminal_ssh_capability_adapter.dart';
import 'webview_feature_adapters.dart';

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
    feature_lan_share.LanShareDatabaseFactory? lanShareDatabaseFactory,
    feature_ai.AiModuleDatabaseFactory? aiDatabaseFactory,
    feature_playbook.PlaybookModuleDatabaseFactory? playbookDatabaseFactory,
    feature_rag.RagDatabaseFactory? ragDatabaseFactory,
    feature_rag.RagCacheStoreFactory? ragCacheStoreFactory,
    feature_mcp.McpModuleDatabaseFactory? mcpDatabaseFactory,
    bool? lanShareReceiverEnabled,
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
    final webViewService = feature_webview.ClientWebViewService(logger: logger);
    final webViewSettingsAdapter = AppWebViewSettingsAdapter(appSettings);
    final developerLogAdapter = AppDeveloperLogAdapter(logger);
    final developerSettingsAdapter = AppDeveloperSettingsAdapter(appSettings);
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
    final terminalSshManager = AppTerminalSshSessionManager(sshService);
    unawaited(
      sshService.ensureInitialized().catchError((error, stackTrace) {
        logger.error(
          'SSH service initialization failed',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );

    final playbookSettingsAdapter = AppPlaybookSettingsAdapter(appSettings);
    final playbookConnectionCatalogAdapter =
        AppPlaybookConnectionCatalogAdapter(storageService);
    final playbookModule = feature_playbook.PlaybookModule(
      databaseFactory: playbookDatabaseFactory,
    );
    await playbookModule.register(
      ModuleContext.fromMap({
        feature_playbook.PlaybookSettingsPort: playbookSettingsAdapter,
        feature_playbook.PlaybookConnectionCatalogPort:
            playbookConnectionCatalogAdapter,
        feature_playbook.PlaybookSshPort: AppPlaybookSshAdapter(sshService),
        feature_playbook.PlaybookLoggerPort: AppPlaybookLoggerAdapter(logger),
        feature_playbook.PlaybookDataProtectionPort:
            AppPlaybookDataProtectionAdapter(DataProtectionService.instance),
      }),
    );
    await playbookModule.initialize();
    await playbookModule.activate();
    storageService.attachPlaybookRepository(playbookModule.repository);

    final ragSettingsAdapter = AppRagSettingsAdapter(
      appSettings,
      storageService,
    );
    final ragModule = feature_rag.RagModule(
      databaseFactory: ragDatabaseFactory,
      cacheStoreFactory: ragCacheStoreFactory,
    );
    await ragModule.register(
      ModuleContext.fromMap({
        feature_rag.RagSettingsPort: ragSettingsAdapter,
        feature_rag.RagLoggerPort: AppRagLoggerAdapter(logger),
      }),
    );
    await ragModule.initialize();
    await ragModule.activate();

    final sftpService = SftpService(storageService);
    final monitoringModule = monitoring.MonitoringModule();
    await monitoringModule.register(
      ModuleContext.fromMap({
        monitoring.MonitoringSshPort: AppMonitoringSshAdapter(sshService),
        monitoring.MonitoringConnectionCatalogPort:
            AppMonitoringConnectionCatalogAdapter(runtimeConnectionRepository),
        monitoring.MonitoringLoggerPort: AppMonitoringLoggerAdapter(logger),
        monitoring.MonitoringBackgroundPort: AppMonitoringBackgroundAdapter(
          appSettings,
        ),
      }),
    );
    await monitoringModule.initialize();
    await monitoringModule.activate();
    final monitoringService = monitoringModule.service;
    final performanceMonitorService = PerformanceMonitorService.fromDelegate(
      monitoringService,
    );
    final aiModule = feature_ai.AiModule(databaseFactory: aiDatabaseFactory);
    final aiStorageAdapter = AppAiStorageAdapter(storageService);
    final aiSettingsAdapter = AppAiSettingsAdapter(appSettings);
    final aiSshAdapter = AppAiSshAdapter(sshService);
    final aiSftpAdapter = AppAiSftpAdapter(sftpService);
    final aiMonitoringAdapter = AppAiMonitoringAdapter(monitoringService);
    final aiClientSystemAdapter = AppAiClientSystemAdapter();
    final aiHealthAdapter = AppAiHealthAdapter(aiClientSystemAdapter);
    final aiWebViewAdapter = AppAiWebViewAdapter(delegate: webViewService);
    final aiServerCatalogAdapter = AppAiServerCatalogAdapter(
      storage: storageService,
      ssh: sshService,
      sftp: sftpService,
    );
    final aiServerDiagnosticsAdapter = AppAiServerDiagnosticsAdapter(
      storage: storageService,
      ssh: sshService,
    );
    final aiRagCapability = AppAiRagCapabilityAdapter(ragModule.service);
    final aiDataProtectionAdapter = AppAiDataProtectionAdapter(
      DataProtectionService.instance,
    );
    final aiLoggerAdapter = AppAiLoggerAdapter(logger);
    await aiModule.register(
      ModuleContext.fromMap({
        feature_ai.AiStoragePort: aiStorageAdapter,
        feature_ai.AiSettingsPort: aiSettingsAdapter,
        feature_ai.AiTextProtectionPort: aiDataProtectionAdapter,
        feature_ai.AiLoggerPort: aiLoggerAdapter,
      }),
    );
    // StorageService 的旧 AI API 只作为兼容外观，第一次调用时才触发
    // AiModule.initialize()，因此普通启动不会创建 ai.db。
    storageService.attachAiRepositoryLoader(() async {
      await aiModule.initialize();
      return aiModule.repository;
    });
    final aiChatRuntimeFactory = feature_ai.AiChatRuntimeFactory(
      storageService: aiStorageAdapter,
      sshService: aiSshAdapter,
      sftpService: aiSftpAdapter,
      performanceMonitorService: aiMonitoringAdapter,
      playbookService: playbookModule.service,
      ragService: aiRagCapability,
      appSettings: aiSettingsAdapter,
      clientSystemToolService: aiClientSystemAdapter,
      clientHealthAdvisor: aiHealthAdapter,
      clientWebViewService: aiWebViewAdapter,
      serverCatalogService: aiServerCatalogAdapter,
      serverDiagnosticsService: aiServerDiagnosticsAdapter,
    );
    final mcpSettingsAdapter = AppMcpSettingsAdapter(appSettings);
    final mcpModule = feature_mcp.McpModule(
      databaseFactory: mcpDatabaseFactory,
    );
    await mcpModule.register(
      ModuleContext.fromMap({
        feature_mcp.McpSettingsPort: mcpSettingsAdapter,
        feature_mcp.McpLoggerPort: AppMcpLoggerAdapter(logger),
        feature_mcp.McpToolRuntimePort: AppMcpToolRuntimeAdapter(
          () => AppAiToolExecutorAdapter(
            aiChatRuntimeFactory.createToolService(),
          ),
        ),
      }),
    );
    await mcpModule.initialize();
    await mcpModule.activate();
    final lanShareSettingsAdapter = AppLanShareSettingsAdapter(appSettings);
    final lanShareModule = feature_lan_share.LanShareModule(
      receiverEnabled: lanShareReceiverEnabled,
      databaseFactory: lanShareDatabaseFactory,
    );
    await lanShareModule.register(
      ModuleContext.fromMap({
        feature_lan_share.LanShareSettingsPort: lanShareSettingsAdapter,
        feature_lan_share.LanShareLoggerPort: AppLanShareLoggerAdapter(logger),
        feature_lan_share.LanShareDataProtectionPort:
            AppLanShareDataProtectionAdapter(DataProtectionService.instance),
        feature_lan_share.LanShareNetworkIdentityPort:
            AppLanShareNetworkIdentityAdapter(NetworkIdentityService()),
        feature_lan_share.LanShareNetworkFactory:
            const AppLanShareNetworkFactory(),
        NetworkRuntime: runtimeNetworkRuntime,
      }),
    );
    await lanShareModule.initialize();
    await lanShareModule.activate();
    final developerDiagnosticsAdapter = AppDeveloperDiagnosticsAdapter(
      sshService: sshService,
      ragService: ragModule.service,
      mcpServer: mcpModule.service,
      performanceMonitor: performanceMonitorService,
      logService: logger,
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
      sshSessionManager: terminalSshManager,
      sshService: sshService,
      sftpService: sftpService,
      monitoringModule: monitoringModule,
      monitoringService: monitoringService,
      performanceMonitorService: performanceMonitorService,
      playbookModule: playbookModule,
      playbookSettingsAdapter: playbookSettingsAdapter,
      playbookConnectionCatalogAdapter: playbookConnectionCatalogAdapter,
      ragModule: ragModule,
      ragSettingsAdapter: ragSettingsAdapter,
      mcpModule: mcpModule,
      mcpSettingsAdapter: mcpSettingsAdapter,
      lanShareModule: lanShareModule,
      lanShareSettingsAdapter: lanShareSettingsAdapter,
      webViewService: webViewService,
      webViewSettingsAdapter: webViewSettingsAdapter,
      developerLogAdapter: developerLogAdapter,
      developerSettingsAdapter: developerSettingsAdapter,
      developerDiagnosticsAdapter: developerDiagnosticsAdapter,
      aiModule: aiModule,
      aiStorageAdapter: aiStorageAdapter,
      aiSettingsAdapter: aiSettingsAdapter,
      aiSshAdapter: aiSshAdapter,
      aiSftpAdapter: aiSftpAdapter,
      aiMonitoringAdapter: aiMonitoringAdapter,
      aiClientSystemAdapter: aiClientSystemAdapter,
      aiHealthAdapter: aiHealthAdapter,
      aiWebViewAdapter: aiWebViewAdapter,
      aiServerCatalogAdapter: aiServerCatalogAdapter,
      aiServerDiagnosticsAdapter: aiServerDiagnosticsAdapter,
      aiChatRuntimeFactory: aiChatRuntimeFactory,
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
