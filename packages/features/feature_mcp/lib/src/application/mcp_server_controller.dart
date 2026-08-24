import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/mcp_activity.dart';
import '../domain/mcp_ports.dart';
import '../domain/mcp_server_settings.dart';
import 'mcp_ai_tool_adapter.dart';
import 'mcp_approval_queue.dart';
import 'mcp_http_server.dart';
import '../domain/mcp_invocation_policy.dart';
import 'mcp_json_rpc.dart';
import 'mcp_lifecycle_handler.dart';
import 'mcp_port_probe.dart';
import 'mcp_self_test_runner.dart';
import '../domain/mcp_tool_description_localizer.dart';
import 'mcp_tool_handler.dart';
import 'mcp_tool_exposure_policy.dart';
import 'lazy_mcp_tool_executor.dart';

/// MCP Server 的生命周期状态。
enum McpServerRunStatus { stopped, checkingPort, starting, running, failed }

class McpToolPolicySnapshot {
  final String name;
  final String description;
  final String? descriptionZh;
  final bool readOnly;
  final bool destructive;
  final McpToolPolicyResult exposureResult;
  final McpInvocationAction invocationAction;
  final String reason;
  final bool exposureConfigurable;
  final bool reviewSelected;
  final bool reviewEligible;

  const McpToolPolicySnapshot({
    required this.name,
    required this.description,
    this.descriptionZh,
    required this.readOnly,
    required this.destructive,
    required this.exposureResult,
    required this.invocationAction,
    required this.reason,
    this.exposureConfigurable = false,
    this.reviewSelected = false,
    this.reviewEligible = false,
  });

  String descriptionFor(bool english) {
    if (english) return description;
    final localized = descriptionZh?.trim();
    return localized == null || localized.isEmpty ? description : localized;
  }

  @Deprecated('Use exposureResult instead')
  McpToolPolicyResult get result => exposureResult;
}

/// Factory used by the controller to own the MCP HTTP server lifecycle.
typedef McpHttpServerFactory =
    Future<McpHttpServerHandle> Function({
      required String host,
      required int port,
      required String token,
      required McpJsonRpcRouter router,
      required McpActivityRecorder? activityRecorder,
      required McpLoggerPort? logger,
    });

Future<McpHttpServerHandle> _bindMcpHttpServer({
  required String host,
  required int port,
  required String token,
  required McpJsonRpcRouter router,
  required McpActivityRecorder? activityRecorder,
  required McpLoggerPort? logger,
}) {
  return McpHttpServer.bind(
    host: host,
    port: port,
    token: token,
    router: router,
    activityRecorder: activityRecorder,
    logger: logger,
  );
}

class McpServerStatusSnapshot {
  final bool enabled;
  final String host;
  final int port;
  final String url;
  final bool running;
  final McpServerRunStatus status;
  final String? lastError;
  final McpPortProbeResult? lastPortProbeResult;
  final DateTime? startedAt;

  const McpServerStatusSnapshot({
    required this.enabled,
    required this.host,
    required this.port,
    required this.url,
    required this.running,
    required this.status,
    this.lastError,
    this.lastPortProbeResult,
    this.startedAt,
  });
}

/// MCP App Scope 服务；拥有 HTTP Server 和审批队列，但不拥有数据库。
class McpServerController extends ChangeNotifier {
  final McpSettingsPort settings;
  final McpToolExecutor Function() toolServiceFactory;
  final McpPortProbe portProbe;
  final McpHttpServerFactory serverFactory;
  final McpSelfTestTransport selfTestTransport;
  final McpActivityRepository activityRepository;
  final McpLoggerPort logger;
  final McpApprovalQueue approvalQueue;

  McpHttpServerHandle? _server;
  McpServerRunStatus _status = McpServerRunStatus.stopped;
  String? _boundHost;
  int? _boundPort;
  String? _lastError;
  McpPortProbeResult? _lastPortProbeResult;
  DateTime? _startedAt;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void> _lifecycleTail = Future<void>.value();
  Future<void>? _closeFuture;
  int _lifecycleGeneration = 0;
  bool _desiredRunning = false;
  McpApprovalMode? _lastApprovalMode;
  Set<String> _lastSecondaryReviewTools = const {};
  Set<String> _lastExposedTools = const {};
  bool _lastExposureToolsConfigured = false;
  String _lastToken = '';

  McpServerController({
    required this.settings,
    required this.toolServiceFactory,
    required this.activityRepository,
    required this.logger,
    this.portProbe = const McpPortProbe(),
    this.serverFactory = _bindMcpHttpServer,
    this.selfTestTransport = const McpHttpSelfTestTransport(),
    McpApprovalQueue? approvalQueue,
  }) : approvalQueue = approvalQueue ?? McpApprovalQueue(logger: logger) {
    _lastApprovalMode = settings.mcpSettings.approvalMode;
    _lastSecondaryReviewTools = settings.mcpSettings.secondaryReviewTools;
    _lastExposedTools = settings.mcpSettings.exposedTools;
    _lastExposureToolsConfigured = settings.mcpSettings.exposureToolsConfigured;
    _lastToken = settings.mcpSettings.token;
    settings.addListener(_handleSettingsChanged);
  }

  McpActivityRecorder get _activityRecorder =>
      McpActivityRecorder(activityRepository, logger: logger);

  bool get running => _server != null && _status == McpServerRunStatus.running;
  McpServerRunStatus get status => _status;
  String? get lastError => _lastError;
  McpPortProbeResult? get lastPortProbeResult => _lastPortProbeResult;

  Future<List<McpActivityRecord>> loadRecentActivity({int limit = 500}) {
    return activityRepository.loadMcpActivityRecords(limit: limit);
  }

  Future<void> clearRecentActivity() async {
    await activityRepository.clearMcpActivityRecords();
    _notify();
  }

  Future<List<McpToolPolicySnapshot>> loadToolPolicySnapshot() async {
    final service = toolServiceFactory();
    final settings = this.settings.mcpSettings;
    final hasChatSession = service is McpChatSessionState
        ? (service as McpChatSessionState).hasChatSession
        : false;
    const policy = McpToolExposurePolicy();
    const invocationPolicy = McpInvocationPolicy();
    const adapter = McpAiToolAdapter();
    final tools = await service.tools();
    return List.unmodifiable(
      [
        for (final tool in tools)
          () {
            final decision = policy.evaluate(
              tool,
              settings: settings,
              hasChatSession: hasChatSession,
            );
            final invocation = invocationPolicy.evaluate(
              tool: tool,
              settings: settings,
            );
            final annotations = adapter.toMcpTool(tool)['annotations'] as Map;
            return McpToolPolicySnapshot(
              name: tool.name,
              description: tool.description,
              descriptionZh: McpToolDescriptionLocalizer.descriptionFor(
                tool,
                english: false,
              ),
              readOnly: annotations['readOnlyHint'] == true,
              destructive: annotations['destructiveHint'] == true,
              exposureResult: decision.result,
              invocationAction: invocation.action,
              reason: decision.result == McpToolPolicyResult.exposed
                  ? invocation.reason
                  : decision.reason,
              exposureConfigurable: decision.configurable,
              reviewSelected: settings.secondaryReviewTools.contains(tool.name),
              reviewEligible: _isReviewEligible(tool, annotations),
            );
          }(),
      ]..sort((a, b) => a.name.compareTo(b.name)),
    );
  }

  void rejectPendingApprovalsForPolicyChange() {
    approvalQueue.rejectAll();
  }

  bool _isReviewEligible(McpTool tool, Map annotations) {
    return tool.executionMode == McpToolExecutionMode.stateChanging ||
        tool.executionMode == McpToolExecutionMode.executionOnly ||
        annotations['destructiveHint'] == true ||
        McpInvocationPolicy.defaultSecondaryReviewTools.contains(tool.name);
  }

  void _handleSettingsChanged() {
    final current = settings.mcpSettings;
    final mode = current.approvalMode;
    final tools = current.secondaryReviewTools;
    final exposedTools = current.exposedTools;
    final exposureToolsConfigured = current.exposureToolsConfigured;
    final token = current.token;
    final changed =
        mode != _lastApprovalMode ||
        !_setEquals(tools, _lastSecondaryReviewTools) ||
        exposureToolsConfigured != _lastExposureToolsConfigured ||
        !_setEquals(exposedTools, _lastExposedTools) ||
        token != _lastToken;
    _lastApprovalMode = mode;
    _lastSecondaryReviewTools = tools;
    _lastExposedTools = exposedTools;
    _lastExposureToolsConfigured = exposureToolsConfigured;
    _lastToken = token;
    if (changed) rejectPendingApprovalsForPolicyChange();
    _notify();
  }

  bool _setEquals(Set<String> left, Set<String> right) {
    return left.length == right.length && left.containsAll(right);
  }

  McpServerStatusSnapshot get snapshot {
    final settings = this.settings.mcpSettings;
    final host = running ? (_boundHost ?? settings.host) : settings.host;
    final port = running ? (_boundPort ?? settings.port) : settings.port;
    return McpServerStatusSnapshot(
      enabled: settings.enabled,
      host: host,
      port: port,
      url: 'http://$host:$port/mcp',
      running: running,
      status: _status,
      lastError: _lastError,
      lastPortProbeResult: _lastPortProbeResult,
      startedAt: _startedAt,
    );
  }

  Future<void> startIfEnabled() async {
    try {
      await settings.ensureCoreLoaded();
    } catch (error) {
      if (_disposed) return;
      logger.error(
        'MCP settings failed to load before server start',
        details:
            'errorCode=settings_load_failed errorType=${error.runtimeType}',
      );
      _setFailed('settings_load_failed');
      return;
    }
    if (!_disposed && settings.mcpSettings.enabled) {
      await start();
    }
  }

  Future<McpServerStatusSnapshot> start() {
    if (_disposed) return Future.value(snapshot);
    _desiredRunning = true;
    final generation = ++_lifecycleGeneration;
    return _serializeLifecycle(() => _start(generation));
  }

  Future<McpServerStatusSnapshot> _start(int generation) async {
    if (!_isCurrentStart(generation)) return snapshot;
    if (running) return snapshot;

    unawaited(
      _activityRecorder.record(
        kind: McpActivityKind.lifecycle,
        outcome: McpActivityOutcome.success,
        policyReason: 'start_requested',
      ),
    );

    var settings = this.settings.mcpSettings;
    if (!settings.hasValidHost || !settings.hasValidPort) {
      _setFailed('Invalid MCP host or port');
      return snapshot;
    }

    try {
      await this.settings.ensureMcpServerToken();
      if (!_isCurrentStart(generation)) return snapshot;
      final token = this.settings.mcpSettings.token;
      settings = this.settings.mcpSettings.copyWith(token: token);

      _status = McpServerRunStatus.checkingPort;
      _lastError = null;
      _notify();
      logger.info(
        'MCP server start requested',
        details: 'host=${settings.host} port=${settings.port}',
      );

      final probe = await portProbe.check(
        host: settings.host,
        port: settings.port,
      );
      if (!_isCurrentStart(generation)) return snapshot;
      _lastPortProbeResult = probe;
      logger.info(
        'MCP port check result',
        details:
            'host=${probe.host} port=${probe.port} available=${probe.available} reason=${probe.reason.name}',
      );
      if (!probe.available) {
        _setFailed(
          probe.reason == McpPortProbeReason.invalidHostOrPort
              ? 'Invalid MCP host or port'
              : 'Port is already in use',
        );
        return snapshot;
      }

      _status = McpServerRunStatus.starting;
      _notify();
      final lazyToolExecutor = LazyMcpToolExecutor(toolServiceFactory);
      final router = McpJsonRpcRouter(
        lifecycleHandler: const McpLifecycleHandler(),
        toolHandler: McpToolHandler(
          aiToolService: lazyToolExecutor,
          settingsProvider: () => this.settings.mcpSettings,
          activityRecorder: _activityRecorder,
          approvalQueue: approvalQueue,
          hasChatSession: () {
            return false;
          },
          logger: logger,
        ),
      );
      final server = await serverFactory(
        host: settings.host,
        port: settings.port,
        token: token,
        router: router,
        activityRecorder: _activityRecorder,
        logger: logger,
      );
      if (!_isCurrentStart(generation)) {
        await _closeSupersededServer(server);
        return snapshot;
      }
      _server = server;
      _boundHost = settings.host;
      _boundPort = settings.port;
      _startedAt = DateTime.now();
      _lastError = null;
      _status = McpServerRunStatus.running;
      unawaited(
        _activityRecorder.record(
          kind: McpActivityKind.lifecycle,
          outcome: McpActivityOutcome.success,
          policyReason: 'server_started',
        ),
      );
      logger.info(
        'MCP server started',
        details: 'url=http://${settings.host}:${settings.port}/mcp',
      );
      _notify();
      return snapshot;
    } on SocketException catch (error) {
      if (!_isCurrentStart(generation)) return snapshot;
      logger.error(
        'MCP server failed to start',
        details:
            'host=${settings.host} port=${settings.port} '
            'errorCode=server_bind_failed errorType=${error.runtimeType}',
      );
      _setFailed('server_bind_failed');
      return snapshot;
    } catch (error) {
      if (!_isCurrentStart(generation)) return snapshot;
      logger.error(
        'MCP server failed to start',
        details:
            'host=${settings.host} port=${settings.port} '
            'errorCode=server_start_failed errorType=${error.runtimeType}',
      );
      _setFailed('server_start_failed');
      return snapshot;
    }
  }

  Future<void> stop() {
    approvalQueue.rejectAll();
    _desiredRunning = false;
    _lifecycleGeneration += 1;
    if (_disposed) return Future<void>.value();
    return _serializeLifecycle(_stop);
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    _boundHost = null;
    _boundPort = null;
    _startedAt = null;
    if (server != null) {
      await server.close();
      logger.info('MCP server stopped');
    }
    _status = McpServerRunStatus.stopped;
    _lastError = null;
    if (!_disposed) {
      unawaited(
        _activityRecorder.record(
          kind: McpActivityKind.lifecycle,
          outcome: McpActivityOutcome.success,
          policyReason: 'server_stopped',
        ),
      );
    }
    _notify();
  }

  Future<McpServerStatusSnapshot> restart() async {
    await stop();
    return start();
  }

  Future<McpPortProbeResult> checkPort({String? host, int? port}) {
    return _serializeLifecycle(() => _checkPort(host: host, port: port));
  }

  Future<McpPortProbeResult> _checkPort({String? host, int? port}) async {
    final settings = this.settings.mcpSettings;
    final wasRunning = running;
    if (!wasRunning) {
      _status = McpServerRunStatus.checkingPort;
      _notify();
    }
    final result = await portProbe.check(
      host: host ?? settings.host,
      port: port ?? settings.port,
    );
    _lastPortProbeResult = result;
    logger.info(
      'MCP port check result',
      details:
          'host=${result.host} port=${result.port} available=${result.available} reason=${result.reason.name}',
    );
    if (!wasRunning) {
      _status = McpServerRunStatus.stopped;
    }
    _notify();
    return result;
  }

  bool _isCurrentStart(int generation) {
    return !_disposed && _desiredRunning && generation == _lifecycleGeneration;
  }

  Future<T> _serializeLifecycle<T>(Future<T> Function() action) {
    final previous = _lifecycleTail;
    final result = Completer<T>();
    _lifecycleTail = () async {
      await previous;
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    return result.future;
  }

  Future<void> _closeSupersededServer(McpHttpServerHandle server) async {
    try {
      await server.close();
    } catch (error) {
      logger.error(
        'Superseded MCP server failed to close',
        details: 'errorType=${error.runtimeType}',
      );
    }
  }

  /// 使新生命周期动作立即失效，并等待所有在途 start/stop 与 HTTP Server 收敛。
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _disposed = true;
    _desiredRunning = false;
    _lifecycleGeneration += 1;
    settings.removeListener(_handleSettingsChanged);
    approvalQueue.rejectAll();
    final future = _serializeLifecycle(_closeResources);
    _closeFuture = future;
    return future;
  }

  Future<void> _closeResources() async {
    final server = _server;
    _server = null;
    _boundHost = null;
    _boundPort = null;
    _startedAt = null;
    _status = McpServerRunStatus.stopped;
    _lastError = null;
    if (server != null) await _closeSupersededServer(server);
    approvalQueue.dispose();
  }

  Future<McpSelfTestResult> runSelfTest() async {
    return McpSelfTestRunner(
      transport: selfTestTransport,
      activityRecorder: _activityRecorder,
    ).run(
      serverRunning: running,
      url: Uri.parse(snapshot.url),
      loadToken: settings.ensureMcpServerToken,
    );
  }

  void _setFailed(String error) {
    _status = McpServerRunStatus.failed;
    _lastError = error;
    unawaited(
      _activityRecorder.record(
        kind: McpActivityKind.lifecycle,
        outcome: McpActivityOutcome.failed,
        policyReason: 'server_start_failed',
      ),
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    unawaited(close());
    _notifierDisposed = true;
    super.dispose();
  }
}
