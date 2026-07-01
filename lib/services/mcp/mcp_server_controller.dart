import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ai_tool_service.dart';
import '../app_log_service.dart';
import '../app_settings.dart';
import 'mcp_http_server.dart';
import 'mcp_json_rpc.dart';
import 'mcp_lifecycle_handler.dart';
import 'mcp_port_probe.dart';
import 'mcp_tool_handler.dart';

enum McpServerRunStatus {
  stopped,
  checkingPort,
  starting,
  running,
  failed,
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

  McpHttpServer? _server;
  McpServerRunStatus _status = McpServerRunStatus.stopped;
  String? _boundHost;
  int? _boundPort;
  String? _lastError;
  McpPortProbeResult? _lastPortProbeResult;
  DateTime? _startedAt;
  bool _disposed = false;

  McpServerController({
    required this.appSettings,
    required this.toolServiceFactory,
    this.portProbe = const McpPortProbe(),
  });

  bool get running => _server != null && _status == McpServerRunStatus.running;
  McpServerRunStatus get status => _status;
  String? get lastError => _lastError;
  McpPortProbeResult? get lastPortProbeResult => _lastPortProbeResult;

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
    await appSettings.initFuture;
    if (appSettings.mcpServerEnabled) {
      await start();
    }
  }

  Future<McpServerStatusSnapshot> start() async {
    if (running) return snapshot;

    var settings = appSettings.mcpSettings;
    if (!settings.hasValidHost || !settings.hasValidPort) {
      _setFailed('Invalid MCP host or port');
      return snapshot;
    }

    final token = await appSettings.ensureMcpServerToken();
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
      final toolService = toolServiceFactory();
      final router = McpJsonRpcRouter(
        lifecycleHandler: const McpLifecycleHandler(),
        toolHandler: McpToolHandler(
          aiToolService: toolService,
          settingsProvider: () => appSettings.mcpSettings,
          hasChatSession: () {
            if (toolService is AiToolService) {
              return toolService.clientWebViewSessionId != null;
            }
            return false;
          },
        ),
      );
      _server = await McpHttpServer.bind(
        host: settings.host,
        port: settings.port,
        token: token,
        router: router,
      );
      _boundHost = settings.host;
      _boundPort = settings.port;
      _startedAt = DateTime.now();
      _lastError = null;
      _status = McpServerRunStatus.running;
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
    _notify();
  }

  Future<McpServerStatusSnapshot> restart() async {
    await stop();
    return start();
  }

  Future<McpPortProbeResult> checkPort({
    String? host,
    int? port,
  }) async {
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

  void _setFailed(String error) {
    _status = McpServerRunStatus.failed;
    _lastError = error;
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
    unawaited(_server?.close());
    super.dispose();
  }
}
