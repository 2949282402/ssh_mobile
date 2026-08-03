import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ai_tool_service.dart';
import '../app_log_service.dart';
import '../app_settings.dart';
import 'mcp_activity.dart';
import 'mcp_ai_tool_adapter.dart';
import 'mcp_approval_queue.dart';
import 'mcp_http_server.dart';
import 'mcp_invocation_policy.dart';
import 'mcp_json_rpc.dart';
import 'mcp_lifecycle_handler.dart';
import 'mcp_port_probe.dart';
import 'mcp_server_settings.dart';
import 'mcp_tool_description_localizer.dart';
import 'mcp_tool_handler.dart';
import 'mcp_tool_exposure_policy.dart';
import 'lazy_ai_tool_executor.dart';

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

class McpSelfTestResult {
  final bool serverReachable;
  final bool authenticated;
  final bool initialized;
  final bool toolsListed;
  final int durationMs;
  final String? failureCode;

  const McpSelfTestResult({
    required this.serverReachable,
    required this.authenticated,
    required this.initialized,
    required this.toolsListed,
    required this.durationMs,
    this.failureCode,
  });

  bool get succeeded =>
      serverReachable && authenticated && initialized && toolsListed;
}

class _McpSelfTestRequestResult {
  final bool reachable;
  final int? statusCode;
  final bool succeeded;

  const _McpSelfTestRequestResult({
    required this.reachable,
    required this.statusCode,
    required this.succeeded,
  });
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

class McpServerController extends ChangeNotifier {
  final AppSettings appSettings;
  final AiToolExecutor Function() toolServiceFactory;
  final McpPortProbe portProbe;
  final McpActivityRepository? activityRepository;
  final McpApprovalQueue approvalQueue;

  McpHttpServer? _server;
  McpServerRunStatus _status = McpServerRunStatus.stopped;
  String? _boundHost;
  int? _boundPort;
  String? _lastError;
  McpPortProbeResult? _lastPortProbeResult;
  DateTime? _startedAt;
  bool _disposed = false;
  McpApprovalMode? _lastApprovalMode;
  Set<String> _lastSecondaryReviewTools = const {};
  String _lastToken = '';

  McpServerController({
    required this.appSettings,
    required this.toolServiceFactory,
    this.portProbe = const McpPortProbe(),
    this.activityRepository,
    McpApprovalQueue? approvalQueue,
  }) : approvalQueue = approvalQueue ?? McpApprovalQueue() {
    _lastApprovalMode = appSettings.mcpApprovalMode;
    _lastSecondaryReviewTools = appSettings.mcpSecondaryReviewTools;
    _lastToken = appSettings.mcpServerToken;
    appSettings.addListener(_handleSettingsChanged);
  }

  McpActivityRecorder? get _activityRecorder {
    final repository = activityRepository;
    return repository == null ? null : McpActivityRecorder(repository);
  }

  bool get running => _server != null && _status == McpServerRunStatus.running;
  McpServerRunStatus get status => _status;
  String? get lastError => _lastError;
  McpPortProbeResult? get lastPortProbeResult => _lastPortProbeResult;

  Future<List<McpActivityRecord>> loadRecentActivity({int limit = 500}) {
    final repository = activityRepository;
    return repository?.loadMcpActivityRecords(limit: limit) ??
        Future.value(const []);
  }

  Future<void> clearRecentActivity() async {
    await activityRepository?.clearMcpActivityRecords();
    _notify();
  }

  Future<List<McpToolPolicySnapshot>> loadToolPolicySnapshot() async {
    final service = toolServiceFactory();
    final settings = appSettings.mcpSettings;
    final hasChatSession =
        service is AiToolService && service.clientWebViewSessionId != null;
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
              reviewEligible:
                  decision.result == McpToolPolicyResult.exposed &&
                  _isReviewEligible(tool, annotations),
            );
          }(),
      ]..sort((a, b) => a.name.compareTo(b.name)),
    );
  }

  void rejectPendingApprovalsForPolicyChange() {
    approvalQueue.rejectAll();
  }

  bool _isReviewEligible(AiTool tool, Map annotations) {
    return tool.executionMode == AiToolExecutionMode.stateChanging ||
        tool.executionMode == AiToolExecutionMode.executionOnly ||
        annotations['destructiveHint'] == true ||
        McpInvocationPolicy.defaultSecondaryReviewTools.contains(tool.name);
  }

  void _handleSettingsChanged() {
    final mode = appSettings.mcpApprovalMode;
    final tools = appSettings.mcpSecondaryReviewTools;
    final token = appSettings.mcpServerToken;
    final changed =
        mode != _lastApprovalMode ||
        !_setEquals(tools, _lastSecondaryReviewTools) ||
        token != _lastToken;
    _lastApprovalMode = mode;
    _lastSecondaryReviewTools = tools;
    _lastToken = token;
    if (changed) rejectPendingApprovalsForPolicyChange();
    _notify();
  }

  bool _setEquals(Set<String> left, Set<String> right) {
    return left.length == right.length && left.containsAll(right);
  }

  McpServerStatusSnapshot get snapshot {
    final settings = appSettings.mcpSettings;
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
    await appSettings.ensureCoreLoaded();
    if (appSettings.mcpServerEnabled) {
      await start();
    }
  }

  Future<McpServerStatusSnapshot> start() async {
    if (running) return snapshot;

    unawaited(
      _activityRecorder?.record(
            kind: McpActivityKind.lifecycle,
            outcome: McpActivityOutcome.success,
            policyReason: 'start_requested',
          ) ??
          Future.value(),
    );

    var settings = appSettings.mcpSettings;
    if (!settings.hasValidHost || !settings.hasValidPort) {
      _setFailed('Invalid MCP host or port');
      return snapshot;
    }

    await appSettings.ensureMcpToken();
    final token = appSettings.mcpServerToken;
    settings = appSettings.mcpSettings.copyWith(token: token);

    _status = McpServerRunStatus.checkingPort;
    _lastError = null;
    _notify();
    AppLogService.instance.info(
      'MCP server start requested',
      details: 'host=${settings.host} port=${settings.port}',
    );

    final probe = await portProbe.check(
      host: settings.host,
      port: settings.port,
    );
    _lastPortProbeResult = probe;
    AppLogService.instance.info(
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
    try {
      final lazyToolExecutor = LazyAiToolExecutor(toolServiceFactory);
      final router = McpJsonRpcRouter(
        lifecycleHandler: const McpLifecycleHandler(),
        toolHandler: McpToolHandler(
          aiToolService: lazyToolExecutor,
          settingsProvider: () => appSettings.mcpSettings,
          activityRecorder: _activityRecorder,
          approvalQueue: approvalQueue,
          hasChatSession: () {
            return false;
          },
        ),
      );
      _server = await McpHttpServer.bind(
        host: settings.host,
        port: settings.port,
        token: token,
        router: router,
        activityRecorder: _activityRecorder,
      );
      _boundHost = settings.host;
      _boundPort = settings.port;
      _startedAt = DateTime.now();
      _lastError = null;
      _status = McpServerRunStatus.running;
      unawaited(
        _activityRecorder?.record(
              kind: McpActivityKind.lifecycle,
              outcome: McpActivityOutcome.success,
              policyReason: 'server_started',
            ) ??
            Future.value(),
      );
      AppLogService.instance.info(
        'MCP server started',
        details: 'url=http://${settings.host}:${settings.port}/mcp',
      );
      _notify();
      return snapshot;
    } on SocketException catch (e, stackTrace) {
      AppLogService.instance.error(
        'MCP server failed to start',
        error: e,
        stackTrace: stackTrace,
        details: 'host=${settings.host} port=${settings.port}',
      );
      _setFailed(e.message);
      return snapshot;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'MCP server failed to start',
        error: e,
        stackTrace: stackTrace,
        details: 'host=${settings.host} port=${settings.port}',
      );
      _setFailed(e.toString());
      return snapshot;
    }
  }

  Future<void> stop() async {
    approvalQueue.rejectAll();
    final server = _server;
    _server = null;
    _boundHost = null;
    _boundPort = null;
    _startedAt = null;
    if (server != null) {
      await server.close();
      AppLogService.instance.info('MCP server stopped');
    }
    _status = McpServerRunStatus.stopped;
    _lastError = null;
    unawaited(
      _activityRecorder?.record(
            kind: McpActivityKind.lifecycle,
            outcome: McpActivityOutcome.success,
            policyReason: 'server_stopped',
          ) ??
          Future.value(),
    );
    _notify();
  }

  Future<McpServerStatusSnapshot> restart() async {
    await stop();
    return start();
  }

  Future<McpPortProbeResult> checkPort({String? host, int? port}) async {
    final settings = appSettings.mcpSettings;
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
    AppLogService.instance.info(
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

  Future<McpSelfTestResult> runSelfTest() async {
    final watch = Stopwatch()..start();
    if (!running) {
      return _selfTestFailure(
        watch,
        'server_not_running',
        serverReachable: false,
        authenticated: false,
      );
    }
    final token = await appSettings.ensureMcpServerToken();
    final url = Uri.parse(snapshot.url);
    final initialize = await _postJsonRpc(url, token, const {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': McpLifecycleHandler.protocolVersion},
    });
    if (!initialize.reachable) {
      return _selfTestFailure(
        watch,
        'connection_failed',
        serverReachable: false,
        authenticated: false,
      );
    }
    if (initialize.statusCode == HttpStatus.unauthorized ||
        initialize.statusCode == HttpStatus.forbidden) {
      return _selfTestFailure(
        watch,
        'authentication_failed',
        serverReachable: true,
        authenticated: false,
      );
    }
    if (!initialize.succeeded) {
      return _selfTestFailure(
        watch,
        'initialize_failed',
        serverReachable: true,
        authenticated: true,
      );
    }
    final toolsListed = await _postJsonRpc(url, token, const {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    if (!toolsListed.succeeded) {
      return _selfTestFailure(
        watch,
        'tools_list_failed',
        serverReachable: toolsListed.reachable,
        authenticated: toolsListed.reachable,
        initialized: true,
      );
    }
    watch.stop();
    final result = McpSelfTestResult(
      serverReachable: true,
      authenticated: true,
      initialized: true,
      toolsListed: true,
      durationMs: watch.elapsedMilliseconds,
    );
    unawaited(
      _activityRecorder?.record(
            kind: McpActivityKind.protocol,
            outcome: McpActivityOutcome.success,
            method: 'self_test',
            durationMs: result.durationMs,
          ) ??
          Future.value(),
    );
    return result;
  }

  Future<_McpSelfTestRequestResult> _postJsonRpc(
    Uri url,
    String token,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      final responseText = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        return _McpSelfTestRequestResult(
          reachable: true,
          statusCode: response.statusCode,
          succeeded: false,
        );
      }
      final decoded = jsonDecode(responseText);
      return _McpSelfTestRequestResult(
        reachable: true,
        statusCode: response.statusCode,
        succeeded: decoded is Map && decoded['error'] == null,
      );
    } catch (_) {
      return const _McpSelfTestRequestResult(
        reachable: false,
        statusCode: null,
        succeeded: false,
      );
    } finally {
      client.close(force: true);
    }
  }

  McpSelfTestResult _selfTestFailure(
    Stopwatch watch,
    String code, {
    required bool serverReachable,
    required bool authenticated,
    bool initialized = false,
  }) {
    watch.stop();
    final result = McpSelfTestResult(
      serverReachable: serverReachable,
      authenticated: authenticated,
      initialized: initialized,
      toolsListed: false,
      durationMs: watch.elapsedMilliseconds,
      failureCode: code,
    );
    unawaited(
      _activityRecorder?.record(
            kind: McpActivityKind.protocol,
            outcome: McpActivityOutcome.failed,
            method: 'self_test',
            policyReason: code,
            durationMs: result.durationMs,
          ) ??
          Future.value(),
    );
    return result;
  }

  void _setFailed(String error) {
    _status = McpServerRunStatus.failed;
    _lastError = error;
    unawaited(
      _activityRecorder?.record(
            kind: McpActivityKind.lifecycle,
            outcome: McpActivityOutcome.failed,
            policyReason: 'server_start_failed',
          ) ??
          Future.value(),
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
    _disposed = true;
    appSettings.removeListener(_handleSettingsChanged);
    approvalQueue.rejectAll();
    approvalQueue.dispose();
    unawaited(_server?.close());
    super.dispose();
  }
}
