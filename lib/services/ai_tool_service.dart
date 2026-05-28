import 'dart:async';
import 'dart:convert';

import '../models/connection.dart';
import 'app_log_service.dart';
import 'client_system_tool_service.dart';
import 'client_webview_service.dart';
import 'sftp_service.dart';
import 'server_status_probe.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

abstract interface class AiToolExecutor {
  Future<List<AiTool>> tools();

  Future<List<Map<String, dynamic>>> toolDefinitions();

  AiToolApprovalRequest? approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  );

  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  });

  AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  });
}

/// AI Function Calling（工具调用）定义与调度中心。
///
/// 架构：
/// - AiTool 是纯数据类：name + description + JSON Schema properties + handler function
/// - 18 个工具分三类：client 端工具（剪贴板、闹钟、时间、设备信息）、
///   server 端工具（命令执行、OS 检测、SFTP）、诊断工具（性能、端口、进程、ops report）
/// - 命令安全三级审查：只读(自动) → 需审批(弹窗) → 已拦截(拒绝)
/// - 所有 server 工具使用一次性 SSH exec 连接（非 tmux），不与用户终端环境混合
class AiToolService implements AiToolExecutor {
  final StorageService storageService;
  final SshClientAdapter sshService;
  final SftpClientAdapter sftpService;
  final ClientSystemToolService clientSystemToolService;
  final ClientWebViewService clientWebViewService;
  final String? clientWebViewSessionId;

  AiToolService({
    required this.storageService,
    required this.sshService,
    required this.sftpService,
    ClientSystemToolService? clientSystemToolService,
    ClientWebViewService? clientWebViewService,
    this.clientWebViewSessionId,
  })  : clientSystemToolService =
            clientSystemToolService ?? ClientSystemToolService.instance,
        clientWebViewService =
            clientWebViewService ?? ClientWebViewService.instance;

  @override
  Future<List<AiTool>> tools() async {
    final searchSettings = await storageService.loadAiConnectionSettings();
    return [
      if (searchSettings.webSearchEnabled)
        AiTool(
          name: 'web_search',
          description:
              'Search the public web from the SSH Mobile client WebView bound to the current chat session. Return cited result URLs. Use this before answering questions about current, latest, news, or external information.',
          properties: {
            'query': _string('Search query. Keep it concise.'),
            'limit': {
              'type': 'integer',
              'description':
                  'Maximum number of results to return. Defaults to the app setting.',
            },
          },
          required: const ['query'],
          handler: _webSearch,
        ),
      AiTool(
        name: 'client_get_time',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get the client system time, UTC time, timezone, and locale.',
        properties: const {},
        handler: (_) async => jsonEncode(
          clientSystemToolService.getClientTime(),
        ),
      ),
      AiTool(
        name: 'client_get_device_info',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client OS/platform, locale, timezone, hostname, CPU count, and supported client integrations.',
        properties: const {},
        handler: (_) async => jsonEncode(
          clientSystemToolService.getClientDeviceInfo(),
        ),
      ),
      AiTool(
        name: 'client_get_network_info',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client network status such as connectivity, transport, Wi-Fi details where available, and proxy/VPN indicators.',
        properties: const {},
        handler: (_) async => jsonEncode(
          await clientSystemToolService.getNetworkInfo(),
        ),
      ),
      AiTool(
        name: 'client_get_battery_status',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Get client battery level, charging state, battery saver, and app battery-optimization exemption status where available.',
        properties: const {},
        handler: (_) async => jsonEncode(
          await clientSystemToolService.getBatteryStatus(),
        ),
      ),
      AiTool(
        name: 'client_open_app_settings',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Open the operating system app settings page so the user can grant notifications, battery, or background permissions.',
        properties: const {},
        handler: (_) async => jsonEncode(
          await clientSystemToolService.openAppSettings(),
        ),
      ),
      AiTool(
        name: 'client_set_clipboard',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Copy text to the client clipboard. Use for commands, reports, snippets, or connection notes the user wants to paste elsewhere.',
        properties: {
          'text': _string('Text to place on the client clipboard.'),
        },
        required: const ['text'],
        handler: _clientSetClipboard,
      ),
      AiTool(
        name: 'client_set_alarm',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Set a client-side alarm/reminder. On Android it can also request the system Clock app to create an alarm; other platforms use an in-app local notification while the app remains alive.',
        properties: {
          'triggerAt': _string(
            'Optional. Local ISO-8601 datetime, or 24-hour time like 08:30. If omitted, use delaySeconds or delayMinutes.',
          ),
          'delaySeconds': {
            'type': 'integer',
            'description': 'Optional delay in seconds.',
          },
          'delayMinutes': {
            'type': 'integer',
            'description': 'Optional delay in minutes.',
          },
          'label': _string('Optional alarm/reminder label.'),
          'useSystemAlarm': {
            'type': 'boolean',
            'description':
                'Optional. Default true. Android-only request to create a system Clock alarm.',
          },
        },
        handler: _clientSetAlarm,
      ),
      AiTool(
        name: 'client_list_alarms',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. List in-app client reminders created by client_set_alarm during this app process.',
        properties: const {},
        handler: (_) async => jsonEncode(
          await clientSystemToolService.listAlarms(),
        ),
      ),
      AiTool(
        name: 'client_cancel_alarm',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Cancel an in-app client reminder created by client_set_alarm.',
        properties: {
          'alarmId': _string('Alarm id returned by client_set_alarm.'),
        },
        required: const ['alarmId'],
        handler: _clientCancelAlarm,
      ),
      AiTool(
        name: 'client_webview_get_page_text',
        description:
            'CLIENT tool. Runs on the user device running SSH Mobile, not on any SSH server. Read visible plain text from the WebView page bound to the current chat session. It does not read images, hidden DOM data, passwords, or cross-origin iframe contents.',
        properties: {
          'maxChars': {
            'type': 'integer',
            'description':
                'Optional maximum characters to return. Defaults to 40000 and is capped at 100000.',
          },
        },
        handler: _clientWebViewGetPageText,
      ),
      AiTool(
        name: 'list_servers',
        description: 'List saved SSH servers. Does not reveal credentials.',
        properties: const {},
        handler: (_) async => _listServers(),
      ),
      AiTool(
        name: 'detect_os',
        description:
            'Detect whether a selected SSH server is Windows or Linux/Unix before choosing OS-specific commands.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _detectOsTool,
      ),
      AiTool(
        name: 'run_command',
        description:
            'Run a shell command on a selected server. The saved server platform is enforced: use Linux/POSIX commands only on Linux servers, and explicit cmd /c or PowerShell diagnostics only on Windows servers. Delete/remove commands are blocked.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'command': _string(
            'Shell command to run. On Windows use explicit cmd /c or powershell/pwsh read-only diagnostics. On Linux use POSIX/Linux commands such as uname, ps, ss, df, cat. Delete/remove commands are not supported.',
          ),
        },
        required: const ['connectionId', 'command'],
        handler: (arguments) => _runCommand(arguments),
      ),
      AiTool(
        name: 'sftp_list_dir',
        description: 'List a remote directory through SFTP.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote directory path. Defaults to ".".'),
        },
        required: const ['connectionId'],
        handler: _listDir,
      ),
      AiTool(
        name: 'sftp_read_text',
        description:
            'Read a small remote text file through SFTP. Binary and large files are rejected.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'path': _string('Remote text file path.'),
        },
        required: const ['connectionId', 'path'],
        handler: _readText,
      ),
      AiTool(
        name: 'get_server_status',
        description:
            'Get read-only server status for diagnostics. Modes: performance, ports, applications, or all.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'mode': _string(
            'Status mode: performance, ports, applications, or all. Defaults to all.',
          ),
        },
        required: const ['connectionId'],
        handler: _serverStatus,
      ),
      AiTool(
        name: 'generate_ops_report',
        description:
            'Collect read-only server status and return an operations report payload with health score, risks, ports, applications, and suggested next checks.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _opsReport,
      ),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    return (await tools()).map((tool) => tool.definition).toList();
  }

  @override
  AiToolApprovalRequest? approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) {
    if (name != 'run_command') return null;
    final connectionId = _arg(arguments, 'connectionId');
    final command = _arg(arguments, 'command');
    final config = storageService.getConnection(connectionId);
    final review = reviewCommand(command, platform: config?.serverPlatform);
    if (!review.requiresApproval) return null;
    return AiToolApprovalRequest(
      toolName: name,
      connectionId: connectionId,
      connectionName: config?.name ?? connectionId,
      command: command,
      reason: review.reason,
    );
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    for (final tool in await tools()) {
      if (tool.name == name) {
        final startedAt = DateTime.now();
        AppLogService.instance.info(
          'AI tool started',
          details: 'tool=$name args=${_safeArguments(arguments)}',
        );
        try {
          final result = name == 'run_command'
              ? await _runCommand(arguments, approvedWrite: approvedWrite)
              : await tool.handler(arguments);
          AppLogService.instance.info(
            'AI tool completed',
            details:
                'tool=$name elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} resultChars=${result.length}',
          );
          return result;
        } catch (e, stackTrace) {
          AppLogService.instance.error(
            'AI tool failed',
            error: e,
            stackTrace: stackTrace,
            details: 'tool=$name args=${_safeArguments(arguments)}',
          );
          rethrow;
        }
      }
    }
    AppLogService.instance.warning('Unknown AI tool requested', details: name);
    return jsonEncode({'error': 'Unknown tool: $name'});
  }

  String _listServers() {
    final servers = storageService.connections
        .map(
          (item) => {
            'id': item.id,
            'name': item.name,
            'host': item.host,
            'port': item.port,
            'username': item.username,
            'launchMode': item.launchMode.name,
            'serverPlatform': item.serverPlatform.name,
          },
        )
        .toList();
    return jsonEncode({'servers': servers});
  }

  Future<String> _webSearch(Map<String, dynamic> arguments) async {
    final settings = await storageService.loadAiConnectionSettings();
    if (!settings.webSearchEnabled) {
      return jsonEncode({
        'execution': 'client',
        'target': 'client_webview',
        'provider': 'local_webview',
        'error': 'Web search is not enabled in LLM settings.',
      });
    }
    final chatId = clientWebViewSessionId;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode({
        'execution': 'client',
        'target': 'client_webview',
        'provider': 'local_webview',
        'hasPage': false,
        'error':
            'No current chat session is bound to this tool call. Open or use the WebView from the current AI chat first.',
      });
    }
    final query = _arg(arguments, 'query');
    final requestedLimit = arguments['limit'];
    final limit = requestedLimit is num
        ? requestedLimit.toInt().clamp(1, settings.webSearchMaxResults)
        : settings.webSearchMaxResults;
    final result = await clientWebViewService.searchWeb(
      chatId,
      query,
      maxResults: limit,
    );
    return jsonEncode(result.toJson());
  }

  Future<String> _clientSetAlarm(Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.setAlarm(
      triggerAt: _optionalString(arguments, 'triggerAt'),
      delaySeconds: _optionalInt(arguments, 'delaySeconds'),
      delayMinutes: _optionalInt(arguments, 'delayMinutes'),
      label: _optionalString(arguments, 'label'),
      useSystemAlarm: _optionalBool(arguments, 'useSystemAlarm') ?? true,
    );
    return jsonEncode(result);
  }

  Future<String> _clientCancelAlarm(Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.cancelAlarm(
      _arg(arguments, 'alarmId'),
    );
    return jsonEncode(result);
  }

  Future<String> _clientSetClipboard(Map<String, dynamic> arguments) async {
    final result = await clientSystemToolService.setClipboard(
      _arg(arguments, 'text'),
    );
    return jsonEncode(result);
  }

  Future<String> _clientWebViewGetPageText(
    Map<String, dynamic> arguments,
  ) async {
    final chatId = clientWebViewSessionId;
    final maxChars = _optionalInt(arguments, 'maxChars') ??
        ClientWebViewService.defaultMaxChars;
    if (chatId == null || chatId.trim().isEmpty) {
      return jsonEncode({
        'execution': 'client',
        'target': 'client_webview',
        'hasPage': false,
        'error':
            'No current chat session is bound to this tool call. Open the WebView from the current AI chat first.',
      });
    }
    final result = await clientWebViewService.readPlainText(
      chatId,
      maxChars: maxChars,
    );
    return jsonEncode(result.toJson());
  }

  Future<String> _runCommand(
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    final connectionId = _arg(arguments, 'connectionId');
    final command = _arg(arguments, 'command');
    final config = storageService.getConnection(connectionId);
    if (config == null) {
      return jsonEncode({
        'error': 'Connection config not found.',
        'connectionId': connectionId,
      });
    }
    final platform = config.serverPlatform;
    final review = reviewCommand(command, platform: platform);
    if (review.blocked) {
      return jsonEncode({
        'error': review.reason,
        'serverPlatform': platform.name,
        'command': command,
      });
    }
    if (review.requiresApproval && !approvedWrite) {
      return jsonEncode({
        'error': 'Write command requires user approval before execution.',
        'serverPlatform': platform.name,
        'command': command,
      });
    }

    final timeoutSeconds = await storageService.getAiRequestTimeoutSeconds();
    late final RemoteCommandResult result;
    try {
      // This intentionally uses a one-shot SSH exec path, not the tmux-backed
      // terminal session path, so AI tools do not attach to user workspaces.
      // Some diagnostics, such as searching logs under /var or /, can be slow
      // on real servers, so AI tool commands get a longer timeout than UI
      // connection setup.
      result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: command,
        timeout: Duration(seconds: timeoutSeconds),
      );
    } on TimeoutException {
      AppLogService.instance.warning(
        'AI tool command timed out',
        details:
            'connectionId=$connectionId timeoutSeconds=$timeoutSeconds command=${_truncate(command)}',
      );
      return jsonEncode({
        'error':
            'Command timed out after $timeoutSeconds seconds. Narrow the search path or run a smaller diagnostic command.',
        'serverPlatform': platform.name,
        'command': command,
      });
    }
    if (platform == ServerPlatform.windows &&
        _isWindowsPermissionProblem(result.stdout, result.stderr)) {
      return jsonEncode({
        'exitCode': result.exitCode,
        'serverPlatform': platform.name,
        'permissionError': true,
        'error': _windowsPermissionMessage,
        'stdout': _truncate(result.stdout),
        'stderr': _truncate(result.stderr),
        'command': command,
      });
    }
    return jsonEncode({
      'exitCode': result.exitCode,
      'serverPlatform': platform.name,
      'stdout': _truncate(result.stdout),
      'stderr': _truncate(result.stderr),
    });
  }

  Future<String> _detectOsTool(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final detected = await _detectRemoteOs(connectionId);
    return jsonEncode(detected);
  }

  Future<String> _listDir(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = (arguments['path'] as String?)?.trim();
    final entries = await sftpService.listDirectoryForConnection(
      connectionId,
      path?.isNotEmpty == true ? path! : '.',
    );
    return jsonEncode({
      'path': path?.isNotEmpty == true ? path : '.',
      'entries': entries
          .take(200)
          .map(
            (entry) => {
              'name': entry.name,
              'path': entry.path,
              'type': entry.isDirectory ? 'directory' : 'file',
              'size': entry.size,
              'modifiedAt': entry.modifiedAt?.toIso8601String(),
            },
          )
          .toList(),
      if (entries.length > 200) 'truncated': true,
    });
  }

  Future<String> _readText(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final path = _arg(arguments, 'path');
    final text = await sftpService.readTextPathForConnection(
      connectionId: connectionId,
      path: path,
    );
    return jsonEncode({
      'path': path,
      'content': _truncate(text),
      'truncated': text.length > _maxToolTextChars,
    });
  }

  Future<String> _serverStatus(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final mode = (arguments['mode'] as String?)?.trim().toLowerCase();
    final os = await _detectRemoteOs(connectionId);
    if (os['os'] == 'windows') {
      return _windowsServerStatus(connectionId, mode, os);
    }
    final wantPerformance =
        mode == null || mode.isEmpty || mode == 'all' || mode == 'performance';
    final wantPorts =
        mode == null || mode.isEmpty || mode == 'all' || mode == 'ports';
    final wantApplications = mode == null ||
        mode.isEmpty ||
        mode == 'all' ||
        mode == 'applications' ||
        mode == 'apps';
    final payload = <String, dynamic>{
      'connectionId': connectionId,
      'os': os,
    };

    if (wantPerformance) {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: ServerStatusProbe.performanceCommand,
        timeout: const Duration(seconds: 12),
      );
      final raw = ServerStatusProbe.parsePerformanceOutput(result.stdout);
      payload['performance'] = {
        'memoryPercent': raw.counters.memoryPercent,
        'diskUsage': raw.diskUsage.map((item) => item.toJson()).toList(),
        'rawCounters': {
          'cpuTotal': raw.counters.cpuTotal,
          'cpuBusy': raw.counters.cpuBusy,
          'diskBytes': raw.counters.diskBytes,
          'networkBytes': raw.counters.networkBytes,
        },
        'stderr': _truncate(result.stderr),
      };
    }
    if (wantPorts) {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: ServerStatusProbe.portsCommand,
        timeout: const Duration(seconds: 12),
      );
      payload['ports'] = ServerStatusProbe.parsePorts(result.stdout)
          .take(200)
          .map((item) => item.toJson())
          .toList();
      if (result.stderr.trim().isNotEmpty) {
        payload['portsStderr'] = _truncate(result.stderr);
      }
    }
    if (wantApplications) {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: ServerStatusProbe.applicationsCommand,
        timeout: const Duration(seconds: 12),
      );
      payload['applications'] = ServerStatusProbe.parseApplications(
        result.stdout,
      ).map((item) => item.toJson()).toList();
      if (result.stderr.trim().isNotEmpty) {
        payload['applicationsStderr'] = _truncate(result.stderr);
      }
    }
    return jsonEncode(payload);
  }

  Future<String> _opsReport(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final connection = storageService.getConnection(connectionId);
    final os = await _detectRemoteOs(connectionId);
    if (os['os'] == 'windows') {
      final status = jsonDecode(await _windowsServerStatus(
        connectionId,
        'all',
        os,
      )) as Map<String, dynamic>;
      return jsonEncode({
        'connectionId': connectionId,
        'server': connection == null
            ? null
            : {
                'name': connection.name,
                'host': connection.host,
                'port': connection.port,
                'username': connection.username,
              },
        'os': os,
        'health': {
          'level': 'unknown',
          'suggestions': [
            'Review high-memory processes and listening ports.',
            'Use Windows Event Viewer or PowerShell Get-EventLog for deeper diagnostics.',
          ],
        },
        'windowsStatus': status['windowsStatus'],
      });
    }
    final performanceResult = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.performanceCommand,
      timeout: const Duration(seconds: 12),
    );
    final portsResult = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.portsCommand,
      timeout: const Duration(seconds: 12),
    );
    final appsResult = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.applicationsCommand,
      timeout: const Duration(seconds: 12),
    );
    final performance =
        ServerStatusProbe.parsePerformanceOutput(performanceResult.stdout);
    final ports = ServerStatusProbe.parsePorts(portsResult.stdout);
    final applications = ServerStatusProbe.parseApplications(appsResult.stdout);
    final diskMax = performance.diskUsage.isEmpty
        ? 0.0
        : performance.diskUsage.map((disk) => disk.usedPercent).reduce(
              (a, b) => a > b ? a : b,
            );
    final risks = <String>[];
    final suggestions = <String>[];
    if (performance.counters.memoryPercent >= 90) {
      risks.add('High memory usage');
      suggestions.add('Inspect top memory processes and recent deploys.');
    }
    if (diskMax >= 85) {
      risks.add('High disk usage');
      suggestions.add('Check large logs, package caches, and old artifacts.');
    }
    if (ports.isEmpty) {
      risks.add('No listening ports returned');
      suggestions.add('Verify service state with systemctl or process list.');
    }
    if (applications.isNotEmpty && applications.first.cpuPercent >= 80) {
      risks.add('A process is consuming high CPU');
      suggestions.add('Inspect the top CPU process and related logs.');
    }
    final score = (100 -
            _opsPenalty(performance.counters.memoryPercent, 70, 95, 40) -
            _opsPenalty(diskMax, 75, 95, 35) -
            (ports.isEmpty ? 10 : 0))
        .clamp(0, 100)
        .round();
    final level = score < 45
        ? 'critical'
        : score < 75
            ? 'warning'
            : 'healthy';
    return jsonEncode({
      'connectionId': connectionId,
      'server': connection == null
          ? null
          : {
              'name': connection.name,
              'host': connection.host,
              'port': connection.port,
              'username': connection.username,
            },
      'health': {
        'score': score,
        'level': level,
        'risks': risks,
        'suggestions': suggestions,
      },
      'performance': {
        'memoryPercent': performance.counters.memoryPercent,
        'diskUsage':
            performance.diskUsage.map((item) => item.toJson()).toList(),
        'rawCounters': {
          'cpuTotal': performance.counters.cpuTotal,
          'cpuBusy': performance.counters.cpuBusy,
          'diskBytes': performance.counters.diskBytes,
          'networkBytes': performance.counters.networkBytes,
        },
      },
      'ports': ports.take(80).map((item) => item.toJson()).toList(),
      'applications':
          applications.take(40).map((item) => item.toJson()).toList(),
      'stderr': {
        if (performanceResult.stderr.trim().isNotEmpty)
          'performance': _truncate(performanceResult.stderr),
        if (portsResult.stderr.trim().isNotEmpty)
          'ports': _truncate(portsResult.stderr),
        if (appsResult.stderr.trim().isNotEmpty)
          'applications': _truncate(appsResult.stderr),
      },
    });
  }

  /// 健康评分惩罚函数：单指标超出阈值时线性扣分。
  /// value: 当前值（如内存 85%），warning/critical: 阈值，maxPenalty: 满分扣。
  /// 例：内存 85%(超 70) → 扣 (85-70)/(95-70)*40 = 24 分
  double _opsPenalty(
    double value,
    double warning,
    double critical,
    double maxPenalty,
  ) {
    if (value <= warning) return 0;
    if (value >= critical) return maxPenalty;
    return (value - warning) / (critical - warning) * maxPenalty;
  }

  String _arg(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.trim().isEmpty) {
      throw StateError('Missing tool argument: $key');
    }
    return value.trim();
  }

  String? _optionalString(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _optionalInt(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool? _optionalBool(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is bool) return value;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case 'yes':
        case '1':
          return true;
        case 'false':
        case 'no':
        case '0':
          return false;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _detectRemoteOs(String connectionId) async {
    final config = storageService.getConnection(connectionId);
    if (config != null) {
      return {
        'os': config.serverPlatform.name,
        'method': 'saved_server_platform',
        'details':
            'Configured as ${config.serverPlatform.displayName} in the server settings.',
      };
    }
    try {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: 'cmd /c ver',
        timeout: const Duration(seconds: 6),
      );
      final combined = '${result.stdout}\n${result.stderr}'.toLowerCase();
      if (result.exitCode == 0 && combined.contains('windows')) {
        return {
          'os': 'windows',
          'method': 'cmd /c ver',
          'details': _truncate(result.stdout.trim()),
        };
      }
    } catch (_) {}
    try {
      final result = await sshService.runOneShotCommand(
        connectionId: connectionId,
        command: 'uname -a',
        timeout: const Duration(seconds: 6),
      );
      final output = result.stdout.trim();
      if (result.exitCode == 0 && output.isNotEmpty) {
        return {
          'os': 'linux',
          'method': 'uname -a',
          'details': _truncate(output),
        };
      }
    } catch (_) {}
    return {
      'os': 'unknown',
      'method': 'cmd /c ver, uname -a',
      'details':
          'Could not identify the remote OS. Ask the user or use generic read-only checks.',
    };
  }

  Future<String> _windowsServerStatus(
    String connectionId,
    String? mode,
    Map<String, dynamic> os,
  ) async {
    final result = await sshService.runOneShotCommand(
      connectionId: connectionId,
      command: ServerStatusProbe.windowsStatusCommand,
      timeout: const Duration(seconds: 20),
    );
    if (_isWindowsPermissionProblem(result.stdout, result.stderr)) {
      return jsonEncode({
        'connectionId': connectionId,
        'os': os,
        'permissionError': true,
        'error': _windowsPermissionMessage,
        'stderr': _truncate(result.stderr),
      });
    }
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      return jsonEncode({
        'connectionId': connectionId,
        'os': os,
        'error': result.stderr.trim().isEmpty
            ? 'Windows status command failed.'
            : _truncate(result.stderr),
      });
    }
    Object? parsed;
    try {
      parsed = jsonDecode(result.stdout);
    } catch (_) {
      parsed = {'raw': _truncate(result.stdout)};
    }
    return jsonEncode({
      'connectionId': connectionId,
      'os': os,
      'mode': mode?.isEmpty == true ? 'all' : mode ?? 'all',
      'windowsStatus': parsed,
      if (result.stderr.trim().isNotEmpty) 'stderr': _truncate(result.stderr),
    });
  }

  /// 三级命令安全审查。
  ///
  /// 规则：
  /// 1. 拦截危险命令（sudo、删除、dd、提权等）
  /// 2. 只读命令（cat、ls、df、ps、grep 等）→ 自动执行
  /// 3. 其余命令 → 需用户审批
  ///
  /// 同时做跨平台拦截：Linux 命令禁止在 Windows 执行，反之亦然。
  @override
  AiCommandReview reviewCommand(
    String command, {
    ServerPlatform? platform,
  }) {
    final normalized = command.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const AiCommandReview.blocked('Command is empty');
    }

    final deletionReason = _deletionCommandBlockReason(normalized);
    if (deletionReason != null) {
      return AiCommandReview.blocked(deletionReason);
    }

    final blocked = [
      'sudo -s',
      'sudo su',
      ' su ',
      'su -',
      'passwd',
      'sshpass',
      'password=',
      'private key',
    ];
    if (blocked.any(normalized.contains)) {
      return const AiCommandReview.blocked(
        'This command asks for elevated shells, passwords, or secret handling.',
      );
    }

    switch (platform) {
      case ServerPlatform.windows:
        return _reviewWindowsCommand(normalized);
      case ServerPlatform.linux:
        return _reviewLinuxCommand(normalized);
      case null:
        return const AiCommandReview.blocked(
          'Server platform is unknown. Configure the server as Linux or Windows before running commands.',
        );
    }
  }

  AiCommandReview _reviewLinuxCommand(String normalized) {
    if (_looksLikeWindowsShellCommand(normalized)) {
      return const AiCommandReview.blocked(
        'Windows command was requested for a Linux server. Use POSIX/Linux commands for this server.',
      );
    }

    // Keep model-operated shell access intentionally narrow: diagnostics and
    // path discovery run directly; everything else pauses for user approval.
    if (_hasCommandSeparator(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Command chaining or piping requires user approval.',
      );
    }
    final allowedPrefixes = [
      'cat ',
      'command -v ',
      'df ',
      'du ',
      'env',
      'free',
      'head ',
      'printenv',
      'readlink ',
      'realpath ',
      'journalctl ',
      'ls',
      'netstat ',
      'ps ',
      'pwd',
      'ss ',
      'stat ',
      'systemctl status ',
      'tail ',
      'top ',
      'uname',
      'uptime',
      'whereis ',
      'which ',
      'whoami',
    ];
    if (!allowedPrefixes.any(normalized.startsWith) &&
        !_isSafePowerShellDiagnostic(normalized)) {
      return const AiCommandReview.requiresApproval(
        'This command may change server state.',
      );
    }
    return const AiCommandReview.readOnly();
  }

  AiCommandReview _reviewWindowsCommand(String normalized) {
    if (_looksLikeLinuxShellCommand(normalized)) {
      return const AiCommandReview.blocked(
        'Linux/POSIX command was requested for a Windows server. Use explicit cmd /c or PowerShell commands for this server.',
      );
    }
    if (_isSafePowerShellDiagnostic(normalized)) {
      return const AiCommandReview.readOnly();
    }
    const safeCmdPrefixes = [
      'cmd /c cd',
      'cmd /c dir',
      'cmd /c echo',
      'cmd /c hostname',
      'cmd /c ipconfig',
      'cmd /c netstat',
      'cmd /c systeminfo',
      'cmd /c tasklist',
      'cmd /c type',
      'cmd /c ver',
      'cmd /c whoami',
    ];
    if (_hasCommandSeparator(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Command chaining or piping requires user approval.',
      );
    }
    if (safeCmdPrefixes.any(normalized.startsWith)) {
      return const AiCommandReview.readOnly();
    }
    if (normalized.startsWith('cmd /c ') ||
        normalized.startsWith('powershell ') ||
        normalized.startsWith('pwsh ')) {
      return const AiCommandReview.requiresApproval(
        'This Windows command may change server state.',
      );
    }
    return const AiCommandReview.blocked(
      'Windows server commands must be explicit: use cmd /c or powershell/pwsh so the tool can enforce Windows safety rules.',
    );
  }

  /// 删除命令拦截：识别 rm -rf、del、remove-item 等破坏性操作。
  /// 使用正则匹配（而非简单前缀），避免误拦 `rm file.txt`（只删一个文件需审批）
  /// 而拦截 `rm -rf /`。
  String? _deletionCommandBlockReason(String normalized) {
    final text = normalized
        .replaceAll(RegExp(r'''["'`]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (text.contains(' remove-') || text.startsWith('remove-')) {
      return 'Delete/remove commands are blocked for AI tools. Use the app UI and explicit filename confirmation for any manual SFTP deletion.';
    }
    final deletePatterns = [
      RegExp(
        r'(^|[\s;&|()])(rm|unlink|rmdir|shred|trash-put)(\.exe)?([\s;&|()]|$)',
      ),
      RegExp(r'(^|[\s;&|()])(del|erase|rd)(\.exe)?([\s;&|()]|$)'),
      RegExp(r'(^|[\s;&|()])find([\s;&|()].*)\s-delete([\s;&|()]|$)'),
      RegExp(
        r'(^|[\s;&|()])(docker|podman|kubectl|git)\s+(rm|rmi|delete)([\s;&|()]|$)',
      ),
      RegExp(
        r'(^|[\s;&|()])(sc|reg|schtasks|netsh)\s+delete([\s;&|()]|$)',
      ),
    ];
    if (!deletePatterns.any((pattern) => pattern.hasMatch(text))) return null;
    return 'Delete/remove commands are blocked for AI tools. Use the app UI and explicit filename confirmation for any manual SFTP deletion.';
  }

  bool _looksLikeWindowsShellCommand(String normalized) {
    const prefixes = [
      'cmd ',
      'cmd.exe ',
      'powershell ',
      'powershell.exe ',
      'pwsh ',
      'pwsh.exe ',
      'wmic ',
      'tasklist',
      'systeminfo',
      'ipconfig',
    ];
    return prefixes.any(normalized.startsWith);
  }

  bool _looksLikeLinuxShellCommand(String normalized) {
    const prefixes = [
      './',
      '/',
      'awk ',
      'bash ',
      'cat ',
      'command -v ',
      'df ',
      'du ',
      'env',
      'free',
      'grep ',
      'head ',
      'journalctl ',
      'ls',
      'printenv',
      'ps ',
      'pwd',
      'readlink ',
      'realpath ',
      'sed ',
      'sh ',
      'ss ',
      'stat ',
      'systemctl ',
      'tail ',
      'top ',
      'uname',
      'uptime',
      'whereis ',
      'which ',
      'whoami',
      'zsh ',
    ];
    return prefixes.any(normalized.startsWith);
  }

  bool _hasCommandSeparator(String normalized) {
    return normalized.contains(';') ||
        normalized.contains('|') ||
        normalized.contains('&&') ||
        normalized.contains('||') ||
        normalized.contains(' & ');
  }

  bool _isSafePowerShellDiagnostic(String normalized) {
    final isPowerShell =
        normalized.startsWith('powershell ') || normalized.startsWith('pwsh ');
    if (!isPowerShell) return false;
    const blockedFragments = [
      ' add-',
      ' clear-',
      ' copy-',
      ' disable-',
      ' enable-',
      ' invoke-',
      ' move-',
      ' new-',
      ' out-file',
      ' remove-',
      ' rename-',
      ' restart-',
      ' set-',
      ' start-',
      ' stop-',
      ' write-',
      '>>',
      '>',
      ';',
      '&&',
      '||',
      ' del ',
      ' erase ',
      ' rd ',
      ' rmdir ',
    ];
    if (blockedFragments.any(normalized.contains)) return false;
    const safeFragments = [
      'get-',
      'select-object',
      'sort-object',
      'measure-object',
      'where-object',
      'convertto-json',
      r'$psversiontable',
      '[system.environment]',
    ];
    return safeFragments.any(normalized.contains);
  }

  bool _isWindowsPermissionProblem(String stdout, String stderr) {
    final combined = '$stdout\n$stderr'.toLowerCase();
    const needles = [
      'access is denied',
      'access denied',
      'administrator privileges',
      'administrator rights',
      'elevation is required',
      'requires elevation',
      'requested operation requires elevation',
      'run as administrator',
      'not have sufficient privilege',
      'not have the required privilege',
      'unauthorizedaccessexception',
      '拒绝访问',
      '权限不足',
      '需要提升',
      '管理员权限',
    ];
    return needles.any(combined.contains);
  }

  String get _windowsPermissionMessage =>
      'Windows permission denied: the current account does not have enough privileges for this operation. 当前 Windows 账号权限不足，请使用管理员/已提升权限的账号，或给当前账号授予所需权限后重试。';

  String _truncate(String value) {
    if (value.length <= _maxToolTextChars) return value;
    return '${value.substring(0, _maxToolTextChars)}\n...[truncated]';
  }

  String _safeArguments(Map<String, dynamic> arguments) {
    return jsonEncode(
      arguments.map((key, value) {
        final lowerKey = key.toLowerCase();
        if (lowerKey.contains('key') ||
            lowerKey.contains('token') ||
            lowerKey.contains('secret') ||
            lowerKey.contains('password')) {
          return MapEntry(key, '[REDACTED]');
        }
        if (value is String && value.length > 300) {
          return MapEntry(key, '${value.substring(0, 300)}...[truncated]');
        }
        return MapEntry(key, value);
      }),
    );
  }

  static Map<String, dynamic> _string(String description) {
    return {'type': 'string', 'description': description};
  }
}

/// 工具调用审批请求：AI 想执行一个"需审批"级别的命令时触发
class AiToolApprovalRequest {
  final String toolName;
  final String connectionId;
  final String connectionName;
  final String command;
  final String reason;

  const AiToolApprovalRequest({
    required this.toolName,
    required this.connectionId,
    required this.connectionName,
    required this.command,
    required this.reason,
  });
}

/// 用户对工具调用的审批决定：批准/拒绝（含是否终止本轮对话）
class AiToolApprovalDecision {
  final bool approved;
  final bool abort;
  final String? feedback;

  const AiToolApprovalDecision.approved()
      : approved = true,
        abort = false,
        feedback = null;

  const AiToolApprovalDecision.rejected({
    this.abort = true,
    this.feedback,
  }) : approved = false;
}

/// 命令审查结果：三级分级（只读 / 需审批 / 已拦截）
class AiCommandReview {
  final bool requiresApproval;
  final bool blocked;
  final String reason;

  const AiCommandReview.readOnly()
      : requiresApproval = false,
        blocked = false,
        reason = 'Read-only diagnostic command.';

  const AiCommandReview.requiresApproval(this.reason)
      : requiresApproval = true,
        blocked = false;

  const AiCommandReview.blocked(this.reason)
      : requiresApproval = false,
        blocked = true;
}

/// 工具定义：name + description + JSON Schema + handler function
class AiTool {
  final String name;
  final String description;
  final Map<String, dynamic> properties;
  final List<String> required;
  final Future<String> Function(Map<String, dynamic> arguments) handler;

  const AiTool({
    required this.name,
    required this.description,
    required this.properties,
    required this.handler,
    this.required = const [],
  });

  Map<String, dynamic> get definition {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
          'additionalProperties': false,
        },
      },
    };
  }
}

const int _maxToolTextChars = 12000;
