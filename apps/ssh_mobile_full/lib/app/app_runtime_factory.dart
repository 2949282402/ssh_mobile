import 'dart:async';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_developer/feature_developer.dart' as developer;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_webview/feature_webview.dart' as feature_webview;
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:path_provider/path_provider.dart';

import '../core/services/data_protection_service.dart';
import '../services/app_bootstrap_coordinator.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/telemetry/app_crash_telemetry_bridge.dart';
import '../services/telemetry/build_metadata_provider.dart';
import '../services/telemetry/drift_telemetry_storage.dart';
import '../services/telemetry/network_telemetry_bridge.dart';
import '../services/telemetry/telemetry_database.dart';
import '../services/telemetry/telemetry_database/telemetry_database_constants.dart';
import '../services/telemetry/telemetry_factory.dart';
import '../services/telemetry/telemetry_span.dart';
import '../services/display_mode_service.dart';
import '../services/network/network_identity_service.dart';
import '../services/network/network_service.dart';
import '../services/sftp_service.dart';
import '../services/terminal_session_metadata_store.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';
import 'app_runtime.dart';
import 'app_runtime_initialization_owner.dart';
import 'ai_external_capability_adapters.dart';
import 'ai_feature_adapters.dart';
import 'developer_feature_adapters.dart';
import 'lan_share_feature_adapters.dart';
import 'mcp_feature_adapters.dart';
import 'monitoring_feature_adapters.dart';
import 'network_sdk_adapters.dart';
import 'playbook_feature_adapters.dart';
import 'ssh_native_stream_adapters.dart';
import 'rag_feature_adapters.dart';
import 'realtime_feature_adapters.dart';
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
  ///
  /// [disposeLogger] 默认 [true]，生产行为不变；回归测试可以关闭它，避免
  /// 销毁跨用例共享的 `AppLogService` 全局单例。
  static Future<AppRuntime> create({
    AppLogService? appLogService,
    connection_core.ConnectionDatabase? connectionDatabase,
    connection_core.ConnectionRepository? connectionRepository,
    connection_core.CredentialRepository? credentialRepository,
    connection_core.HostKeyRepository? hostKeyRepository,
    NetworkRuntime? networkRuntime,
    NetworkIdentityService? networkIdentityService,
    feature_lan_share.LanShareDatabaseFactory? lanShareDatabaseFactory,
    feature_ai.AiModuleDatabaseFactory? aiDatabaseFactory,
    feature_playbook.PlaybookModuleDatabaseFactory? playbookDatabaseFactory,
    feature_rag.RagDatabaseFactory? ragDatabaseFactory,
    feature_rag.RagCacheStoreFactory? ragCacheStoreFactory,
    feature_mcp.McpModuleDatabaseFactory? mcpDatabaseFactory,
    bool? lanShareReceiverEnabled,
    bool disposeLogger = true,
    void Function(String event)? lifecycleObserver,
  }) async {
    final logger = appLogService ?? AppLogService();
    final cleanup = _CleanupStack(observer: lifecycleObserver);
    final pendingInitialization = AppRuntimeInitializationOwner(
      onError: (description, error, stackTrace) {
        logger.error(description, error: error, stackTrace: stackTrace);
      },
    );
    if (disposeLogger) {
      cleanup.add(logger.dispose, priority: _CleanupPriority.logger);
    }

    try {
      logger.install();
      logger.info('Application bootstrap started');

      final runtimeConnectionDatabase =
          connectionDatabase ?? connection_core.ConnectionDatabase();
      cleanup.add(
        runtimeConnectionDatabase.dispose,
        priority: _CleanupPriority.database,
      );
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
      // Network identity is App Scope state. Load it before creating the
      // native runtime so every later consumer (Facade and LAN Feature) uses
      // the same Ed25519/X25519 bundle.
      final runtimeNetworkIdentityService =
          networkIdentityService ?? NetworkIdentityService();
      final networkIdentity = await runtimeNetworkIdentityService
          .loadOrCreate();
      final runtimeNetworkRuntime = networkRuntime ?? NetworkRuntimeImpl();
      cleanup.add(
        runtimeNetworkRuntime.dispose,
        priority: _CleanupPriority.network,
      );
      final traceRegistry = TelemetryTraceRegistry();
      cleanup.add(traceRegistry.dispose, priority: _CleanupPriority.adapter);
      final runtimeRealtimeClient = RealtimeClientImpl(
        backend: AppRealtimeSessionBackend(
          networkRuntime: runtimeNetworkRuntime,
        ),
      );
      cleanup.add(
        runtimeRealtimeClient.dispose,
        priority: _CleanupPriority.realtime,
      );
      final bootstrapClient = JsonBootstrapClient(
        executor: const AppSdkRequestExecutor(),
      );
      pendingInitialization.add(
        start: (_) => runtimeConnectionRepository.initialize(),
        description: 'Connection repository initialization failed',
      );

      // 这些任务原本由 main 并发发起，继续保持不阻塞 runApp 的行为；其
      // Future 由 Runtime 持有并在关闭前等待，避免失败后悬空运行。
      pendingInitialization.add(
        start: (_) => SharedPreferences.getInstance(),
        description: 'SharedPreferences initialization failed',
      );
      pendingInitialization.add(
        start: (_) => DisplayModeService.enableHighRefreshRate(),
        description: 'High refresh-rate setup failed',
      );

      final appSettings = AppSettings();
      cleanup.add(appSettings.dispose, priority: _CleanupPriority.settings);
      final webViewService = feature_webview.ClientWebViewService(
        logger: logger,
        networkLoader: feature_webview.ClientWebViewSafeNetworkLoader(
          resolver: const AppWebViewDnsResolver(),
          transport: const AppWebViewPinnedTransport(),
        ),
      );
      cleanup.add(webViewService.dispose, priority: _CleanupPriority.adapter);
      final webViewSettingsAdapter = AppWebViewSettingsAdapter(appSettings);
      cleanup.add(
        webViewSettingsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final developerLogAdapter = AppDeveloperLogAdapter(logger);
      cleanup.add(
        developerLogAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final developerSettingsAdapter = AppDeveloperSettingsAdapter(appSettings);
      cleanup.add(
        developerSettingsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final terminalMetadataStore = TerminalSessionMetadataStore();
      cleanup.add(
        terminalMetadataStore.dispose,
        priority: _CleanupPriority.metadata,
      );
      final bootstrapCoordinator = AppBootstrapCoordinator(
        appSettings: appSettings,
      );
      cleanup.add(
        bootstrapCoordinator.dispose,
        priority: _CleanupPriority.adapter,
      );
      pendingInitialization.add(
        start: (_) => bootstrapCoordinator.ensureBootstrap(),
        description: 'App bootstrap initialization failed',
      );

      final shortcutCommandService = ShortcutCommandService()..init();
      cleanup.add(
        shortcutCommandService.dispose,
        priority: _CleanupPriority.adapter,
      );

      late final NetworkFacade networkFacade;
      // The LAN Module owns the enrolled-peer trust/native endpoint catalog.
      // Keep this late binding inside the composition root: SSH/SFTP are
      // constructed before the facade-backed LAN Module, but no caller can
      // use them until this factory returns and the module is initialized.
      late final feature_lan_share.LanShareModule lanShareModule;

      String? resolvePeerIdForConfig(connection_core.ConnectionConfig config) {
        final moduleState = lanShareModule.state;
        if (moduleState == ModuleState.registered ||
            moduleState == ModuleState.disposed) {
          return null;
        }
        return lanShareModule.coordinator.peerRegistry.peerIdForHost(
          config.host,
        );
      }

      final sshNativeStreamConnector = AppSshNativeStreamConnector(
        gatewayProvider: () => runtimeNetworkRuntime.openCommandGateway(),
        openerDeviceIdProvider: () async {
          await appSettings.ensureLanIdentity();
          return appSettings.lanDeviceId;
        },
        facadeProvider: () => networkFacade,
        traceRegistry: traceRegistry,
      );
      cleanup.add(
        sshNativeStreamConnector.closeAll,
        priority: _CleanupPriority.ssh,
      );
      final sshService = SshService(
        connectionRepository: runtimeConnectionRepository,
        credentialRepository: runtimeCredentialRepository,
        hostKeyRepository: runtimeHostKeyRepository,
        terminalMetadataStore: terminalMetadataStore,
        appSettings: appSettings,
        nativeStreamConnector: sshNativeStreamConnector,
        peerIdResolver: resolvePeerIdForConfig,
      );
      final terminalSshManager = AppTerminalSshSessionManager(sshService);
      cleanup.add(terminalSshManager.close, priority: _CleanupPriority.ssh);
      pendingInitialization.add(
        start: (_) => sshService.ensureInitialized(),
        cancel: sshService.close,
        description: 'SSH service initialization failed',
      );

      final playbookSettingsAdapter = AppPlaybookSettingsAdapter(appSettings);
      cleanup.add(
        playbookSettingsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final playbookConnectionCatalogAdapter =
          AppPlaybookConnectionCatalogAdapter(runtimeConnectionRepository);
      cleanup.add(
        playbookConnectionCatalogAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final playbookModule = feature_playbook.PlaybookModule(
        databaseFactory: playbookDatabaseFactory,
      );
      cleanup.add(playbookModule.dispose, priority: _CleanupPriority.module);
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

      final aiModule = feature_ai.AiModule(databaseFactory: aiDatabaseFactory);
      cleanup.add(aiModule.dispose, priority: _CleanupPriority.module);
      final aiStorageAdapter = AppAiStorageAdapter(
        connectionRepository: runtimeConnectionRepository,
        credentialRepository: runtimeCredentialRepository,
        hostKeyRepository: runtimeHostKeyRepository,
        playbookRepository: playbookModule.repository,
        aiModule: aiModule,
        terminalMetadataStore: terminalMetadataStore,
      );
      cleanup.add(aiStorageAdapter.dispose, priority: _CleanupPriority.adapter);
      cleanup.add(
        aiStorageAdapter.shutdown,
        priority: _CleanupPriority.adapter,
      );
      aiStorageAdapter.registerOnImportCallback(appSettings.init);
      aiStorageAdapter.registerOnImportCallback(shortcutCommandService.init);
      pendingInitialization.add(
        start: (_) => aiStorageAdapter.init(),
        cancel: aiStorageAdapter.shutdown,
        description: 'AI storage preferences initialization failed',
      );

      final ragSettingsAdapter = AppRagSettingsAdapter(
        appSettings,
        aiStorageAdapter,
      );
      cleanup.add(
        ragSettingsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final ragModule = feature_rag.RagModule(
        databaseFactory: ragDatabaseFactory,
        cacheStoreFactory: ragCacheStoreFactory,
      );
      cleanup.add(ragModule.dispose, priority: _CleanupPriority.module);
      await ragModule.register(
        ModuleContext.fromMap({
          feature_rag.RagSettingsPort: ragSettingsAdapter,
          feature_rag.RagLoggerPort: AppRagLoggerAdapter(logger),
        }),
      );
      await ragModule.initialize();
      await ragModule.activate();

      final sftpService = SftpService(
        connectionRepository: runtimeConnectionRepository,
        credentialRepository: runtimeCredentialRepository,
        hostKeyRepository: runtimeHostKeyRepository,
        nativeStreamConnector: sshNativeStreamConnector,
        peerIdResolver: resolvePeerIdForConfig,
      );
      cleanup.add(sftpService.dispose, priority: _CleanupPriority.sftp);
      final monitoringModule = monitoring.MonitoringModule();
      cleanup.add(monitoringModule.dispose, priority: _CleanupPriority.module);
      await monitoringModule.register(
        ModuleContext.fromMap({
          monitoring.MonitoringSshPort: AppMonitoringSshAdapter(sshService),
          monitoring.MonitoringConnectionCatalogPort:
              AppMonitoringConnectionCatalogAdapter(
                runtimeConnectionRepository,
              ),
          monitoring.MonitoringLoggerPort: AppMonitoringLoggerAdapter(logger),
          monitoring.MonitoringBackgroundPort: AppMonitoringBackgroundAdapter(
            appSettings,
          ),
        }),
      );
      await monitoringModule.initialize();
      await monitoringModule.activate();
      final monitoringService = monitoringModule.service;
      final aiSettingsAdapter = AppAiSettingsAdapter(appSettings);
      cleanup.add(
        aiSettingsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final aiSshAdapter = AppAiSshAdapter(sshService);
      final aiSftpAdapter = AppAiSftpAdapter(sftpService);
      final aiMonitoringAdapter = AppAiMonitoringAdapter(monitoringService);
      final aiClientSystemAdapter = AppAiClientSystemAdapter();
      final aiHealthAdapter = AppAiHealthAdapter(aiClientSystemAdapter);
      final aiWebViewAdapter = AppAiWebViewAdapter(delegate: webViewService);
      final aiServerCatalogAdapter = AppAiServerCatalogAdapter(
        connectionRepository: runtimeConnectionRepository,
        credentialRepository: runtimeCredentialRepository,
        hostKeyRepository: runtimeHostKeyRepository,
        ssh: sshService,
        sftp: sftpService,
      );
      final aiServerDiagnosticsAdapter = AppAiServerDiagnosticsAdapter(
        connectionRepository: runtimeConnectionRepository,
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
      cleanup.add(
        mcpSettingsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      final mcpModule = feature_mcp.McpModule(
        databaseFactory: mcpDatabaseFactory,
      );
      cleanup.add(mcpModule.dispose, priority: _CleanupPriority.module);
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
      cleanup.add(
        lanShareSettingsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );
      await appSettings.ensureLanIdentity();
      final supportDirectory = await getApplicationSupportDirectory();
      final networkReceiveDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}network_receive',
      );
      await networkReceiveDirectory.create(recursive: true);
      await runtimeNetworkRuntime.ensureCapability(NetworkCapability.runtime);
      final networkSessions = NativeNetworkService.fromGateway(
        await runtimeNetworkRuntime.openCommandGateway(),
        traceRegistry: traceRegistry,
      );
      networkFacade = NetworkFacadeImpl(
        sessions: networkSessions,
        realtime: runtimeRealtimeClient,
      );
      cleanup.add(networkFacade.dispose, priority: _CleanupPriority.realtime);
      final configured = await networkFacade.start(
        NetworkRuntimeConfig(
          deviceId: appSettings.lanDeviceId,
          identityPrivateKey: networkIdentity.ed25519PrivateSeed,
          e2ePrivateKey: networkIdentity.x25519PrivateSeed,
          listenAddress: '0.0.0.0:0',
          receiveDirectory: networkReceiveDirectory.path,
        ),
      );
      if (configured is NetworkFailure<void>) {
        throw StateError(
          'App network runtime configuration failed: '
          '${configured.error.code.name}',
        );
      }
      lanShareModule = feature_lan_share.LanShareModule(
        receiverEnabled: lanShareReceiverEnabled,
        databaseFactory: lanShareDatabaseFactory,
      );
      cleanup.add(lanShareModule.dispose, priority: _CleanupPriority.module);
      await lanShareModule.register(
        ModuleContext.fromMap({
          feature_lan_share.LanShareSettingsPort: lanShareSettingsAdapter,
          feature_lan_share.LanShareLoggerPort: AppLanShareLoggerAdapter(
            logger,
          ),
          feature_lan_share.LanShareDataProtectionPort:
              AppLanShareDataProtectionAdapter(DataProtectionService.instance),
          feature_lan_share.LanShareNetworkIdentityPort:
              AppLanShareNetworkIdentityAdapter(runtimeNetworkIdentityService),
          feature_lan_share.LanShareNetworkAccessPort:
              AppLanShareNetworkAccessAdapter(networkFacade),
          BootstrapClient: bootstrapClient,
          NetworkRuntime: runtimeNetworkRuntime,
        }),
      );
      await lanShareModule.initialize();
      await lanShareModule.activate();
      // 这里只登记 AppRuntime 能直接观测到的数据库；Terminal/SFTP 数据库
      // 由 Route Scope 持有，不在 App Scope 诊断中伪装成已打开资源。
      const connectionDatabaseName = 'connection.sqlite';
      const appLogDatabaseName = 'app_logs';
      const aiDatabaseName = 'ai.db';
      const playbookDatabaseName = 'playbook.db';
      const ragDatabaseName = 'rag.db';
      const mcpDatabaseName = 'mcp.db';
      const lanShareDatabaseName = 'lan_share.db';
      // telemetryDatabaseName 由 telemetry_database_constants.dart 提供。

      // 生产遥测存储：SQLite（Drift），绝不使用内存或 JSONL。
      final telemetryDatabase = TelemetryDatabase();
      cleanup.add(telemetryDatabase.dispose, priority: _CleanupPriority.module);
      final telemetryStorage = DriftTelemetryStorage(
        database: telemetryDatabase,
      );
      final telemetryBuildMetadata = await DeviceInfoBuildMetadataProvider()
          .load();
      final relayEnrollmentService =
          lanShareModule.coordinator.relayEnrollmentService;
      final telemetryEnrollmentProvider = relayEnrollmentService == null
          ? null
          : RelayTelemetryEnrollmentProvider(
              relayEnrollment: relayEnrollmentService,
              expectedDeviceId: appSettings.lanDeviceId,
            );
      final telemetryRuntime = await createTelemetryRuntime(
        deviceId: appSettings.lanDeviceId,
        relayEndpoint: appSettings.relayEndpoint,
        buildMetadata: telemetryBuildMetadata,
        deviceEnrollmentProvider: telemetryEnrollmentProvider,
        storage: telemetryStorage,
      );
      final telemetryClient = telemetryRuntime.client;
      cleanup.add(telemetryClient.dispose, priority: _CleanupPriority.module);
      // 业务遥测生产者挂载：SSH / SFTP / 网络路由回退 / 崩溃捕获。
      sshService.telemetryClient = telemetryClient;
      sftpService.telemetryClient = telemetryClient;
      final networkTelemetryBridge = NetworkTelemetryBridge(
        telemetryClient: telemetryClient,
        events: networkFacade.events,
        traceRegistry: traceRegistry,
      );
      networkTelemetryBridge.attach();
      cleanup.add(
        networkTelemetryBridge.dispose,
        priority: _CleanupPriority.adapter,
      );
      final crashTelemetryBridge = AppCrashTelemetryBridge(
        telemetryClient: telemetryClient,
      );
      crashTelemetryBridge.install();
      cleanup.add(
        crashTelemetryBridge.dispose,
        priority: _CleanupPriority.module,
      );
      pendingInitialization.add(
        start: (_) => telemetryClient.record(
          event: TelemetryEvents.appLifecycleStarted,
          properties: {'start_type': 'cold', 'cold_start': true},
        ),
        description: 'Telemetry initial lifecycle event failed',
      );

      final developerDiagnosticsAdapter = AppDeveloperDiagnosticsAdapter(
        sshService: sshService,
        ragService: ragModule.service,
        mcpServer: mcpModule.service,
        performanceMonitor: monitoringService,
        logService: logger,
        telemetryClient: telemetryClient,
        modules: [
          aiModule,
          playbookModule,
          ragModule,
          mcpModule,
          lanShareModule,
          monitoringModule,
        ],
        networkRuntime: runtimeNetworkRuntime,
        databaseDescriptors: [
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'connection_core',
            databaseName: connectionDatabaseName,
            isOpen: () => true,
          ),
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'app_shell',
            databaseName: appLogDatabaseName,
            isOpen: () => logger.databaseOpen,
          ),
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'feature_ai',
            databaseName: aiDatabaseName,
            isOpen: () => _isModuleDatabaseOpen(aiModule),
          ),
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'feature_playbook',
            databaseName: playbookDatabaseName,
            isOpen: () => _isModuleDatabaseOpen(playbookModule),
          ),
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'feature_rag',
            databaseName: ragDatabaseName,
            isOpen: () => _isModuleDatabaseOpen(ragModule),
          ),
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'feature_mcp',
            databaseName: mcpDatabaseName,
            isOpen: () => _isModuleDatabaseOpen(mcpModule),
          ),
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'feature_lan_share',
            databaseName: lanShareDatabaseName,
            isOpen: () => _isModuleDatabaseOpen(lanShareModule),
          ),
          developer.DeveloperDatabaseDescriptor(
            moduleId: 'telemetry',
            databaseName: telemetryDatabaseName,
            isOpen: () => true,
          ),
        ],
      );
      cleanup.add(
        developerDiagnosticsAdapter.dispose,
        priority: _CleanupPriority.adapter,
      );

      final runtime = AppRuntime(
        appLogService: logger,
        appSettings: appSettings,
        connectionDatabase: runtimeConnectionDatabase,
        connectionRepository: runtimeConnectionRepository,
        credentialRepository: runtimeCredentialRepository,
        hostKeyRepository: runtimeHostKeyRepository,
        networkIdentityService: runtimeNetworkIdentityService,
        networkRuntime: runtimeNetworkRuntime,
        networkFacade: networkFacade,
        realtimeClient: runtimeRealtimeClient,
        bootstrapCoordinator: bootstrapCoordinator,
        shortcutCommandService: shortcutCommandService,
        terminalSessionMetadataStore: terminalMetadataStore,
        sshSessionManager: terminalSshManager,
        sshService: sshService,
        sshNativeStreamConnector: sshNativeStreamConnector,
        sftpService: sftpService,
        monitoringModule: monitoringModule,
        monitoringService: monitoringService,
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
        telemetryClient: telemetryClient,
        networkTelemetryBridge: networkTelemetryBridge,
        telemetryTraceRegistry: traceRegistry,
        awaitPendingInitialization: pendingInitialization.wait,
        lifecycleObserver: lifecycleObserver,
        disposeLogger: disposeLogger,
      );
      cleanup.commit();
      pendingInitialization.start();
      return runtime;
    } catch (error, stackTrace) {
      // 构造已经失败，先取消并有界等待所有已启动 initializer；超时后的
      // 迟到错误不会再访问即将释放的 Logger。
      final initializersSettled = await pendingInitialization.cancelAndWait();
      if (!initializersSettled) {
        try {
          logger.warning(
            'Runtime initializer cancellation reached its bounded wait',
          );
        } catch (_) {
          // The original initialization error remains authoritative.
        }
      }
      final cleanupError = await cleanup.dispose();
      if (cleanupError != null) {
        try {
          logger.error(
            'Application bootstrap cleanup failed',
            error: cleanupError.error,
            stackTrace: cleanupError.stackTrace,
          );
        } catch (_) {
          // The original initialization error remains authoritative.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
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

  /// 根据 Module 稳定状态判断其数据库是否已经由 Owner 打开。
  static bool _isModuleDatabaseOpen(AppModule module) => switch (module.state) {
    ModuleState.registered || ModuleState.disposed => false,
    ModuleState.initialized ||
    ModuleState.active ||
    ModuleState.inactive => true,
  };
}

/// Construction-time rollback stack for partially-created App Scope resources.
///
/// Actions are attempted in reverse registration order and an individual
/// cleanup failure never prevents later actions from running. Successful
/// construction transfers ownership to [AppRuntime] via [commit].
final class _CleanupStack {
  _CleanupStack({this._observer});

  /// 可选回滚观察器；只用于生命周期回归测试记录回滚顺序。
  final void Function(String event)? _observer;
  final List<_CleanupAction> _actions = <_CleanupAction>[];
  bool _committed = false;

  void add(FutureOr<void> Function() action, {required int priority}) {
    if (_committed) {
      throw StateError('Cannot register cleanup after ownership transfer.');
    }
    _actions.add(_CleanupAction(callback: action, priority: priority));
  }

  void commit() {
    _committed = true;
    _actions.clear();
  }

  Future<_CleanupFailure?> dispose() async {
    if (_committed) return null;
    _committed = true;
    _CleanupFailure? firstFailure;
    final actions = [..._actions]
      ..sort((left, right) {
        final priority = right.priority.compareTo(left.priority);
        if (priority != 0) return priority;
        return right.sequence.compareTo(left.sequence);
      });
    for (final action in actions) {
      // 只用于生命周期回归测试观察回滚顺序；观察器异常不能改变释放结果。
      _observer?.call('rollback.priority-${action.priority}');
      try {
        await action.callback();
      } catch (error, stackTrace) {
        firstFailure ??= _CleanupFailure(error, stackTrace);
      }
    }
    _actions.clear();
    return firstFailure;
  }
}

final class _CleanupAction {
  _CleanupAction({required this.callback, required this.priority})
    : sequence = _nextSequence++;

  static int _nextSequence = 0;

  final FutureOr<void> Function() callback;
  final int priority;
  final int sequence;
}

/// Cleanup priorities encode the App Scope dependency graph while retaining
/// reverse registration order within each owner group.
abstract final class _CleanupPriority {
  static const logger = 0;
  static const settings = 10;
  static const database = 20;
  static const network = 30;
  static const metadata = 35;
  static const ssh = 40;
  static const sftp = 50;
  static const realtime = 60;
  static const module = 70;
  static const adapter = 80;
}

final class _CleanupFailure {
  const _CleanupFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
