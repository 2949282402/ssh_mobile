part of 'app_runtime_factory.dart';

/// Builds durable telemetry, crash reporting, and developer diagnostics owners.
extension _AppRuntimeFactoryTelemetry on _AppRuntimeFactoryContext {
  Future<void> _prepareTelemetryResources() async {
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
    telemetryDatabase = TelemetryDatabase();
    cleanup.add(telemetryDatabase.dispose, priority: _CleanupPriority.module);
    final telemetryStorage = DriftTelemetryStorage(database: telemetryDatabase);
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
    telemetryClient = telemetryRuntime.client;
    cleanup.add(telemetryClient.dispose, priority: _CleanupPriority.module);
    // 业务遥测生产者挂载：SSH / SFTP / 网络路由回退 / 崩溃捕获。
    sshService.telemetryClient = telemetryClient;
    sftpService.telemetryClient = telemetryClient;
    networkTelemetryBridge = NetworkTelemetryBridge(
      telemetryClient: telemetryClient,
      events: networkFacade.events,
      traceRegistry: traceRegistry,
    );
    networkTelemetryBridge.attach();
    cleanup.add(
      networkTelemetryBridge.dispose,
      priority: _CleanupPriority.adapter,
    );
    crashTelemetryBridge = AppCrashTelemetryBridge(
      telemetryClient: telemetryClient,
    );
    crashTelemetryBridge.install();
    cleanup.add(
      crashTelemetryBridge.dispose,
      priority: _CleanupPriority.module,
    );
    telemetryLogSink = TelemetryLogSink(client: telemetryClient);
    logger.addSink(telemetryLogSink);
    cleanup.add(() async {
      logger.removeSink(telemetryLogSink);
      await telemetryLogSink.close();
    }, priority: _CleanupPriority.module);
    pendingInitialization.add(
      start: (_) => telemetryClient.record(
        event: TelemetryEvents.appLifecycleStarted,
        properties: {'start_type': 'cold', 'cold_start': true},
      ),
      description: 'Telemetry initial lifecycle event failed',
    );

    developerDiagnosticsAdapter = AppDeveloperDiagnosticsAdapter(
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
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(aiModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_playbook',
          databaseName: playbookDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(playbookModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_rag',
          databaseName: ragDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(ragModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_mcp',
          databaseName: mcpDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(mcpModule),
        ),
        developer.DeveloperDatabaseDescriptor(
          moduleId: 'feature_lan_share',
          databaseName: lanShareDatabaseName,
          isOpen: () => AppRuntimeFactory._isModuleDatabaseOpen(lanShareModule),
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

    // Start recovery only after every telemetry producer and sink is attached.
    // An online-at-startup recovery can flush durable backlog immediately, so
    // starting it earlier would race bridge/sink installation.
    telemetryConnectivityMonitor = TelemetryConnectivityMonitor(
      client: telemetryClient,
      source: PlatformTelemetryConnectivitySource(),
    );
    cleanup.add(
      telemetryConnectivityMonitor.dispose,
      priority: _CleanupPriority.adapter,
    );
    await telemetryConnectivityMonitor.start();
  }
}
