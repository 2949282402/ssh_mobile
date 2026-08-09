// AI Feature 的迁移兼容层。
//
// 旧 AI 代码在迁移前直接使用 App Service 类型。本文件只提供同名的包内
// 类型别名和懒运行时默认值，真正实现仍由 App Shell 通过 AiModule 注入，
// 不把 App 实现反向带入 Feature Package。

import 'package:app_core/app_core.dart' as app_core;
import 'package:connection_core/connection_core.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'ai_models.dart';
import 'ai_ports.dart';
import 'ai_webview_models.dart';
import '../data/repositories/ai_repository.dart' as ai_repository;

export 'ai_models.dart';
export 'ai_ports.dart';
export 'ai_webview_models.dart';

typedef AppSettings = AiSettingsPort;
typedef ConnectionTargetBinding = ssh_core.SshTargetBinding;
typedef ConnectionRuntimeTarget = ssh_core.SshRuntimeTarget;
typedef RemoteCommandResult = app_core.RemoteCommandResult;
typedef SshClientAdapter = AiSshPort;
typedef SftpClientAdapter = AiSftpPort;
typedef SshService = AiSshPort;
typedef SftpService = AiSftpPort;
typedef PerformanceMonitorService = AiMonitoringPort;
typedef SshSession = AiSshSessionSnapshot;
typedef TerminalHistoryRecord = AiTerminalHistorySnapshot;
typedef SftpEntry = AiSftpEntrySnapshot;
typedef SftpPathInfo = AiSftpPathSnapshot;
typedef ClientSystemToolAdapter = AiClientSystemPort;
typedef ClientPickedFile = AiPickedFile;
typedef ClientWebViewAdapter = AiWebViewPort;
typedef ClientWebViewSnapshot = AiWebViewSnapshot;
typedef ClientWebViewStateSnapshot = AiWebViewStateSnapshot;
typedef ClientWebViewNavigationResult = AiWebViewNavigationResult;
typedef ClientWebViewSearchResult = AiWebViewSearchResult;
typedef ClientWebViewSearchItem = AiWebViewSearchItem;
typedef ClientRuntimeHealthStatus = AiRuntimeHealthStatus;
typedef ClientHealthCheckProfile = AiHealthProfile;
typedef ClientRuntimeHealthIssue = AiRuntimeHealthIssue;
typedef ClientRuntimeHealthReport = AiRuntimeHealthReport;
typedef ClientHealthAdvisorAdapter = AiHealthPort;
typedef PerformanceMonitorToolAdapter = AiMonitoringPort;
typedef ServerCatalogAdapter = AiServerCatalogPort;
typedef ServerDiagnosticsAdapter = AiServerDiagnosticsPort;
typedef AgentTraceRepository = ai_repository.AgentTraceRepository;

/// 将 App Shell 的 AI Storage Port 轨迹写入能力接到新 Recorder。
final class StorageAgentTraceRepositoryAdapter implements AgentTraceRepository {
  const StorageAgentTraceRepositoryAdapter(this._storage);

  final AiStoragePort _storage;

  @override
  Future<void> saveAgentTraceEvents(List<AgentTraceEvent> events) =>
      _storage.saveAgentTraceEvents(events);
}

/// 迁移期间的默认监控工具包装；生产运行时使用 App Shell 注入的 Port。
final class PerformanceMonitorToolService implements AiMonitoringPort {
  const PerformanceMonitorToolService(this._delegate);

  final AiMonitoringPort _delegate;

  @override
  Future<Map<String, dynamic>> query(app_core.MonitoringQuery request) =>
      _delegate.query(request);

  @override
  Map<String, dynamic> getState() => _delegate.getState();

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) =>
      _delegate.setSelectedServers(connectionIds);

  @override
  Map<String, dynamic> clearSelection() => _delegate.clearSelection();

  @override
  Future<Map<String, dynamic>> start() => _delegate.start();

  @override
  Map<String, dynamic> stop() => _delegate.stop();

  @override
  Map<String, dynamic> stopForConnection(String connectionId) =>
      _delegate.stopForConnection(connectionId);

  @override
  Map<String, dynamic> setInterval(Duration interval) =>
      _delegate.setInterval(interval);

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) =>
      _delegate.setHistoryWindow(window);

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) =>
      _delegate.getHealth(connectionIds: connectionIds);

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) => _delegate.getSamples(
    connectionId,
    visibleOnly: visibleOnly,
    limit: limit,
  );

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) =>
      _delegate.getAlerts(limit: limit);

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) =>
      _delegate.getPorts(connectionId);

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) =>
      _delegate.getApplications(connectionId);

  @override
  Future<Map<String, dynamic>> startWithTargets(
    Map<String, ssh_core.SshTargetBinding> targets,
  ) => _delegate.startWithTargets(targets);
}

/// 未注入服务端目录时的明确失败实现；避免构造 App 全局 Service。
final class ServerCatalogService implements AiServerCatalogPort {
  const ServerCatalogService({
    AiStoragePort? storageService,
    AiSshPort? sshService,
    AiSftpPort? sftpService,
  });

  Map<String, dynamic> _unsupported() => const {
    'supported': false,
    'error': 'Server catalog capability is not available in this context.',
  };

  @override
  List<Map<String, dynamic>> listServerSummaries() => const [];

  @override
  Map<String, dynamic>? getServerDetails(String connectionId) => null;

  @override
  ConnectionConfig buildUpdateCandidate(
    ConnectionConfig current,
    Map<String, dynamic> changes,
  ) => throw StateError('Server catalog capability is not available.');

  @override
  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
    ssh_core.SshTargetBinding? approvedTarget,
    ConnectionConfig? approvedCurrent,
    ConnectionConfig? approvedCandidate,
  }) async => _unsupported();

  @override
  Future<Map<String, dynamic>> deleteServer(String connectionId) async =>
      _unsupported();

  @override
  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds) async =>
      _unsupported();
}

/// 未注入诊断能力时的明确失败实现。
final class ServerDiagnosticsService implements AiServerDiagnosticsPort {
  const ServerDiagnosticsService({
    AiStoragePort? storageService,
    AiSshPort? sshService,
  });

  Map<String, dynamic> _unsupported() => const {
    'supported': false,
    'error': 'Server diagnostics capability is not available in this context.',
  };

  @override
  Future<Map<String, dynamic>> detectOs(String connectionId) async =>
      _unsupported();

  @override
  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  }) async => _unsupported();

  @override
  Future<Map<String, dynamic>> generateOpsReport(String connectionId) async =>
      _unsupported();
}

/// AI 工具使用的设置默认值；避免在工具安全策略中引用 App 实现类。
abstract final class AiSettingsDefaults {
  static const int defaultSftpDownloadLimitBytes = 50 * 1024 * 1024;
  static const int defaultSftpTextEditLimitBytes = 2 * 1024 * 1024;
}

/// 监控目标绑定扩展；仅用于把审批快照交给 Monitoring Port。
abstract interface class BoundPerformanceMonitorToolAdapter
    implements AiMonitoringPort {
  Future<Map<String, dynamic>> startWithTargets(
    Map<String, ConnectionTargetBinding> targets,
  );
}

/// 无副作用的客户端系统默认实现；生产 App 会在 AiModule 中注入真实 Port。
final class _UnavailableClientSystemPort implements AiClientSystemPort {
  const _UnavailableClientSystemPort();

  Map<String, dynamic> _unsupported() => const {
    'supported': false,
    'error': 'Client system capability is not available in this context.',
  };

  @override
  Map<String, dynamic> getClientTime() => _unsupported();

  @override
  Map<String, dynamic> getClientDeviceInfo() => _unsupported();

  @override
  Future<Map<String, dynamic>> getNetworkInfo() async => _unsupported();

  @override
  Future<Map<String, dynamic>> getBatteryStatus() async => _unsupported();

  @override
  Future<Map<String, dynamic>> getPermissionStatus() async => _unsupported();

  @override
  Future<Map<String, dynamic>> openAppSettings() async => _unsupported();

  @override
  Future<Map<String, dynamic>> setClipboard(String text) async =>
      _unsupported();

  @override
  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm = true,
  }) async => _unsupported();

  @override
  Future<Map<String, dynamic>> listAlarms() async => _unsupported();

  @override
  Future<Map<String, dynamic>> cancelAlarm(String alarmId) async =>
      _unsupported();

  @override
  Future<Map<String, dynamic>> queryLogs({
    String? level,
    String? contains,
    int limit = 50,
  }) async => _unsupported();

  @override
  Future<Map<String, dynamic>> getLogCounts() async => _unsupported();

  @override
  Future<Map<String, dynamic>> deleteLogEntries(List<int> ids) async =>
      _unsupported();

  @override
  Future<Map<String, dynamic>> clearLogs() async => _unsupported();

  @override
  Future<Map<String, dynamic>> saveBytesToFile({
    required String fileName,
    required List<int> bytes,
    String? dialogTitle,
  }) async => _unsupported();

  @override
  Future<AiPickedFile?> pickFile({
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) async => null;
}

/// 无副作用的健康检查默认值；未注入时明确返回 unavailable。
final class ClientHealthAdvisor implements AiHealthPort {
  const ClientHealthAdvisor({
    AiClientSystemPort? clientSystemToolService,
    Object? secretPolicy,
  }) : _clientSystemToolService =
           clientSystemToolService ?? const _UnavailableClientSystemPort();

  final AiClientSystemPort _clientSystemToolService;

  @override
  Future<AiRuntimeHealthReport> check({
    AiHealthProfile profile = AiHealthProfile.general,
  }) async {
    final network = await _clientSystemToolService.getNetworkInfo();
    final issue = AiRuntimeHealthIssue(
      code: 'client_health_unavailable',
      severity: AiRuntimeHealthStatus.warning,
      title: 'Client health adapter is not fully configured.',
      detail: network['error']?.toString() ?? 'No client health adapter.',
      recommendation: 'Configure the App Shell health capability.',
    );
    return AiRuntimeHealthReport(
      status: AiRuntimeHealthStatus.warning,
      issues: [issue],
      raw: {'profile': profile.name, 'network': network},
    );
  }
}

/// WebView 的最大正文长度常量归属 AI Contract；Controller 仍留在 Step19。
abstract final class ClientWebViewService {
  static const int defaultMaxChars = aiWebViewDefaultMaxChars;
  static AiWebViewPort get instance => AiRuntimeContext.webView;
}

/// 客户端工具旧静态入口的迁移兼容视图；真实能力由 Module 激活时绑定。
abstract final class ClientSystemToolService {
  static AiClientSystemPort get instance => AiRuntimeContext.clientSystem;
}

/// 迁移期间保留的最小运行时上下文；生命周期由 AiModule 管理。
abstract final class AiRuntimeContext {
  static AiClientSystemPort clientSystem = const _UnavailableClientSystemPort();
  static AiWebViewPort webView = const _UnavailableWebViewPort();
}

final class _UnavailableWebViewPort implements AiWebViewPort {
  const _UnavailableWebViewPort();

  @override
  Future<AiWebViewSnapshot> readPlainText(
    String chatId, {
    int maxChars = aiWebViewDefaultMaxChars,
  }) async => AiWebViewSnapshot(
    chatId: chatId,
    supported: false,
    hasPage: false,
    text: '',
    textLength: 0,
    maxChars: maxChars,
    truncated: false,
    error: 'WebView capability is not available in this context.',
  );

  @override
  Future<AiWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
    String? engine,
  }) async => AiWebViewSearchResult(
    chatId: chatId,
    supported: false,
    query: query,
    results: const [],
    error: 'WebView capability is not available in this context.',
  );

  @override
  Future<AiWebViewStateSnapshot> getState(String chatId) async =>
      AiWebViewStateSnapshot(
        chatId: chatId,
        supported: false,
        hasPage: false,
        progress: 0,
        isLoading: false,
        isAiBrowsing: false,
        canGoBack: false,
        canGoForward: false,
        lastTextLength: 0,
        lastTextTruncated: false,
        error: 'WebView capability is not available in this context.',
      );

  @override
  Future<AiWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  }) async => AiWebViewNavigationResult(
    chatId: chatId,
    supported: false,
    action: action,
    navigated: false,
    blocked: false,
    input: input,
    error: 'WebView capability is not available in this context.',
  );

  @override
  void interruptAiBrowsing(String chatId) {}

  @override
  void clearSession(String chatId) {}
}

/// 迁移期间旧日志静态调用的适配视图。生产实现通过 [AiLoggerContext] 注入。
abstract final class AppLogService {
  static AiLoggerPort get instance => AiLoggerContext.current;
}

typedef AppLanguage = app_core.AppLanguage;
