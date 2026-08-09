import 'package:app_core/app_core.dart' as app_core;
import 'package:feature_developer/feature_developer.dart' as developer;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:flutter/foundation.dart';
import 'package:network_transport/network_transport.dart';

import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/native_memory_service.dart';
import '../services/performance_monitor_service.dart';
import '../services/ssh_service.dart';

/// AppSettings 到 Developer Feature 的最小设置适配器。
///
/// 适配器只转发状态，不拥有 AppSettings；AppRuntime 负责在关闭时释放
/// 监听关系，避免设置对象被 Feature 错误销毁。
final class AppDeveloperSettingsAdapter extends ChangeNotifier
    implements developer.DeveloperSettingsPort {
  /// 创建设置适配器并监听底层设置变化。
  AppDeveloperSettingsAdapter(this._settings) {
    _settings.addListener(_onSettingsChanged);
  }

  final AppSettings _settings;

  @override
  AppLanguage get language => _settings.language;

  @override
  bool get developerMode => _settings.developerMode;

  @override
  bool get floatingPanelEnabled => _settings.developerPanelFloating;

  void _onSettingsChanged() => notifyListeners();

  /// 解除设置监听；底层 AppSettings 由 AppRuntime 继续拥有。
  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}

/// AppLogService 到 Developer Log Port 的脱敏快照适配器。
///
/// Developer Feature 不直接接触旧日志模型，因此日志级别和条目都在这里
/// 转换；写入、脱敏、数据库绑定和磁盘轮转仍由 AppLogService 负责。
final class AppDeveloperLogAdapter extends ChangeNotifier
    implements developer.DeveloperLogPort {
  /// 创建日志适配器并订阅 App Scope 日志变化。
  AppDeveloperLogAdapter(this._logService) {
    _logService.addListener(_onLogsChanged);
  }

  final AppLogService _logService;

  @override
  List<developer.DeveloperLogEntry> get entries => [
    for (final entry in _logService.entries) _toEntry(entry),
  ];

  @override
  Map<developer.DeveloperLogLevel, int> get levelCounts => {
    for (final level in developer.DeveloperLogLevel.values)
      level: _logService.levelCounts[_toAppLevel(level)] ?? 0,
  };

  @override
  List<developer.DeveloperLogEntry> entriesForLevel(
    developer.DeveloperLogLevel level,
  ) => [
    for (final entry in _logService.entriesForLevel(_toAppLevel(level)))
      _toEntry(entry),
  ];

  @override
  Set<int> get entryIds => _logService.entryIds;

  @override
  void deleteEntriesById(Set<int> ids) => _logService.deleteEntriesById(ids);

  @override
  void clear() => _logService.clear();

  void _onLogsChanged() => notifyListeners();

  developer.DeveloperLogEntry _toEntry(AppLogEntry entry) {
    return developer.DeveloperLogEntry(
      id: entry.id,
      time: entry.time,
      level: _toDeveloperLevel(entry.normalizedLevel),
      text: entry.text,
    );
  }

  developer.DeveloperLogLevel _toDeveloperLevel(AppLogLevel level) {
    return switch (level) {
      AppLogLevel.all => developer.DeveloperLogLevel.all,
      AppLogLevel.error => developer.DeveloperLogLevel.error,
      AppLogLevel.warning => developer.DeveloperLogLevel.warning,
      AppLogLevel.info => developer.DeveloperLogLevel.info,
      AppLogLevel.service => developer.DeveloperLogLevel.service,
      AppLogLevel.debug => developer.DeveloperLogLevel.debug,
      AppLogLevel.flutter => developer.DeveloperLogLevel.flutter,
      AppLogLevel.platform => developer.DeveloperLogLevel.platform,
      AppLogLevel.app => developer.DeveloperLogLevel.app,
    };
  }

  AppLogLevel _toAppLevel(developer.DeveloperLogLevel level) {
    return switch (level) {
      developer.DeveloperLogLevel.all => AppLogLevel.all,
      developer.DeveloperLogLevel.error => AppLogLevel.error,
      developer.DeveloperLogLevel.warning => AppLogLevel.warning,
      developer.DeveloperLogLevel.info => AppLogLevel.info,
      developer.DeveloperLogLevel.service => AppLogLevel.service,
      developer.DeveloperLogLevel.debug => AppLogLevel.debug,
      developer.DeveloperLogLevel.flutter => AppLogLevel.flutter,
      developer.DeveloperLogLevel.platform => AppLogLevel.platform,
      developer.DeveloperLogLevel.app => AppLogLevel.app,
    };
  }

  /// 解除日志监听；底层日志 Owner 由 AppRuntime 继续管理。
  @override
  void dispose() {
    _logService.removeListener(_onLogsChanged);
    super.dispose();
  }
}

/// App Scope 服务到 Developer diagnostics contract 的只读适配器。
///
/// Developer Feature 只能观察快照，不能通过该接口启动/停止 SSH、RAG、MCP
/// 或监控。适配器订阅这些服务，以便面板打开时及时刷新状态。
final class AppDeveloperDiagnosticsAdapter extends ChangeNotifier
    implements developer.DeveloperDiagnosticsPort {
  /// 创建 diagnostics 适配器。
  AppDeveloperDiagnosticsAdapter({
    required this.sshService,
    required this.ragService,
    required this.mcpServer,
    required this.performanceMonitor,
    required this.logService,
    required Iterable<app_core.AppModule> modules,
    required this.networkRuntime,
    required Iterable<developer.DeveloperDatabaseDescriptor>
    databaseDescriptors,
  }) : modules = List.unmodifiable(modules),
       databaseDescriptors = List.unmodifiable(databaseDescriptors) {
    _subscriptionsAttached = true;
    for (final source in _sources) {
      source.addListener(_onSourceChanged);
    }
  }

  final SshService sshService;
  final feature_rag.RagService ragService;
  final feature_mcp.McpServerController mcpServer;
  final PerformanceMonitorService performanceMonitor;
  final AppLogService logService;
  final List<app_core.AppModule> modules;
  final NetworkRuntime networkRuntime;
  final List<developer.DeveloperDatabaseDescriptor> databaseDescriptors;
  bool _subscriptionsAttached = false;
  bool _disposed = false;

  List<Listenable> get _sources => [
    sshService,
    ragService,
    mcpServer,
    performanceMonitor,
    logService,
  ];

  /// 当前由该适配器直接持有的 Listenable 订阅数。
  int get activeSubscriptionCount =>
      _subscriptionsAttached ? _sources.length : 0;

  @override
  List<developer.DeveloperComponentStatus> get componentStatuses => [
    developer.DeveloperComponentStatus(
      id: developer.DeveloperComponentId.ssh,
      state:
          '${sshService.sessions.length} session'
          '${sshService.sessions.length == 1 ? '' : 's'}'
          '${sshService.isConnected ? ' · connected' : ''}',
    ),
    developer.DeveloperComponentStatus(
      id: developer.DeveloperComponentId.rag,
      state: _ragState,
    ),
    developer.DeveloperComponentStatus(
      id: developer.DeveloperComponentId.mcpServer,
      state: mcpServer.running ? 'running' : 'stopped',
    ),
    developer.DeveloperComponentStatus(
      id: developer.DeveloperComponentId.performanceMonitor,
      state: _performanceState,
    ),
    developer.DeveloperComponentStatus(
      id: developer.DeveloperComponentId.logBuffer,
      state: '${logService.entries.length} entries',
    ),
  ];

  String get _ragState {
    if (ragService.isLoading) return 'indexing…';
    if (ragService.isInitialized) return 'index loaded';
    return 'idle';
  }

  String get _performanceState {
    if (performanceMonitor.isSampling) return 'sampling';
    if (performanceMonitor.isRunning) return 'running';
    return 'idle';
  }

  @override
  developer.DeveloperDiagnosticsSnapshot get snapshot =>
      developer.DeveloperDiagnosticsSnapshot(
        capturedAt: DateTime.now(),
        modules: [
          for (final module in modules)
            developer.DeveloperModuleSnapshot(
              id: module.id,
              state: module.state,
            ),
        ],
        ssh: developer.DeveloperSshSnapshot(
          activeSessions: sshService.activeSessionCount,
          idleSessions: sshService.idleSessionCount,
          leaseCount: sshService.leaseCount,
        ),
        network: developer.DeveloperNetworkSnapshot(
          activeConnections: networkRuntime.diagnostics.activeConnections,
          nativeHandles: networkRuntime.diagnostics.nativeHandles,
        ),
        databases: [
          for (final descriptor in databaseDescriptors)
            descriptor.readSnapshot(),
        ],
        resources: developer.DeveloperResourceSnapshot(
          activeTimers:
              logService.activeTimerCount +
              (performanceMonitor.isRunning ? 1 : 0) +
              sshService.activeTimerCount,
          activeSubscriptions:
              activeSubscriptionCount + sshService.activeSubscriptionCount,
        ),
      );

  @override
  Future<developer.DeveloperNativeMemorySnapshot?> readNativeMemory() async {
    final snapshot = await NativeMemoryService.instance.snapshot();
    if (snapshot == null) return null;
    return developer.DeveloperNativeMemorySnapshot(
      available: snapshot.available,
      javaHeapBytes: snapshot.javaHeapBytes,
      nativeHeapBytes: snapshot.nativeHeapBytes,
      graphicsBytes: snapshot.graphicsBytes,
      codeBytes: snapshot.codeBytes,
      totalPssBytes: snapshot.totalPssBytes,
    );
  }

  void _onSourceChanged() {
    if (!_disposed) notifyListeners();
  }

  /// 在 Debug 模式检查该适配器已解除全部直接订阅。
  ///
  /// 适配器不拥有底层 Service 的 Timer/native handle，因此这里只断言其
  /// 自己的订阅；底层资源由 AppRuntime 在后续释放阶段分别检查。
  void debugAssertReleased() {
    assert(() {
      if (!_disposed || activeSubscriptionCount != 0) {
        throw StateError(
          'AppDeveloperDiagnosticsAdapter subscriptions were not released.',
        );
      }
      return true;
    }());
  }

  /// 解除所有服务监听；底层服务由 AppRuntime 按自身顺序释放。
  @override
  void dispose() {
    if (_disposed) return;
    for (final source in _sources) {
      source.removeListener(_onSourceChanged);
    }
    _subscriptionsAttached = false;
    _disposed = true;
    super.dispose();
  }
}
