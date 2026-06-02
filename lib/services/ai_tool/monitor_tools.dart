part of '../ai_tool_service.dart';

extension _MonitorTools on AiToolService {
  Future<String> _monitorGetState(Map<String, dynamic> arguments) async {
    return jsonEncode(performanceMonitorToolService.getState());
  }

  Future<String> _monitorSetSelectedServers(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor selection requires user approval.',
      });
    }
    final ids = _stringList(arguments['connectionIds']);
    for (final id in ids) {
      if (storageService.getConnection(id) == null) {
        throw StateError('Unknown connection id: $id');
      }
    }
    return jsonEncode(performanceMonitorToolService.setSelectedServers(ids));
  }

  Future<String> _monitorClearSelection(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor selection requires user approval.',
      });
    }
    return jsonEncode(performanceMonitorToolService.clearSelection());
  }

  Future<String> _monitorStart(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Starting performance monitoring requires user approval.',
      });
    }
    return jsonEncode(await performanceMonitorToolService.start());
  }

  Future<String> _monitorStop(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Stopping performance monitoring requires user approval.',
      });
    }
    return jsonEncode(performanceMonitorToolService.stop());
  }

  Future<String> _monitorStopForConnection(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor state requires user approval.',
      });
    }
    return jsonEncode(
      performanceMonitorToolService.stopForConnection(
        _arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _monitorSetInterval(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor sampling settings requires user approval.',
      });
    }
    final seconds = _argInt(arguments, 'seconds').clamp(2, 300);
    return jsonEncode(
      performanceMonitorToolService.setInterval(Duration(seconds: seconds)),
    );
  }

  Future<String> _monitorSetHistoryWindow(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor history settings requires user approval.',
      });
    }
    final seconds = _argInt(arguments, 'seconds').clamp(30, 600);
    return jsonEncode(
      performanceMonitorToolService
          .setHistoryWindow(Duration(seconds: seconds)),
    );
  }

  Future<String> _monitorGetHealth(Map<String, dynamic> arguments) async {
    return jsonEncode(
      performanceMonitorToolService.getHealth(
        connectionIds: _optionalStringList(arguments, 'connectionIds'),
      ),
    );
  }

  Future<String> _monitorGetSamples(Map<String, dynamic> arguments) async {
    return jsonEncode(
      performanceMonitorToolService.getSamples(
        _arg(arguments, 'connectionId'),
        visibleOnly: _optionalBool(arguments, 'visibleOnly') ?? true,
        limit: _optionalInt(arguments, 'limit') ?? 100,
      ),
    );
  }

  Future<String> _monitorGetAlerts(Map<String, dynamic> arguments) async {
    return jsonEncode(
      performanceMonitorToolService.getAlerts(
        limit: _optionalInt(arguments, 'limit') ?? 50,
      ),
    );
  }

  Future<String> _monitorGetPorts(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await performanceMonitorToolService
          .getPorts(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _monitorGetApplications(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await performanceMonitorToolService.getApplications(
        _arg(arguments, 'connectionId'),
      ),
    );
  }

  List<AiTool> _getMonitorTools() {
    return [
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
      AiTool(
        name: 'monitor_get_state',
        description:
            'Return the app-scoped performance monitor state for selected servers, running status, effective intervals, alerts, and health snapshots.',
        properties: const {},
        handler: _monitorGetState,
      ),
      AiTool(
        name: 'monitor_set_selected_servers',
        description:
            'Replace the performance monitor selected server set. This changes app monitor state and requires user approval.',
        properties: {
          'connectionIds': _stringArray(
            'Server connection ids to select for performance monitoring.',
            minimumItems: 1,
          ),
        },
        required: const ['connectionIds'],
        handler: (arguments) => _monitorSetSelectedServers(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'monitor_clear_selection',
        description:
            'Clear the performance monitor selected server set. This changes app monitor state and requires user approval.',
        properties: const {},
        handler: (arguments) =>
            _monitorClearSelection(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_start',
        description:
            'Start the app-scoped performance monitor for the currently selected servers. This changes app monitor state and requires user approval.',
        properties: const {},
        handler: (arguments) => _monitorStart(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_stop',
        description:
            'Stop the app-scoped performance monitor. This changes app monitor state and requires user approval.',
        properties: const {},
        handler: (arguments) => _monitorStop(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_stop_for_connection',
        description:
            'Stop the app-scoped performance monitor for one connection id. This changes app monitor state and requires user approval.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: (arguments) => _monitorStopForConnection(
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'monitor_set_interval',
        description:
            'Set the app-scoped performance monitor sampling interval in seconds. This changes app monitor state and requires user approval.',
        properties: {
          'seconds': _int('Sampling interval in seconds.', minimum: 2),
        },
        required: const ['seconds'],
        handler: (arguments) =>
            _monitorSetInterval(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_set_history_window',
        description:
            'Set the app-scoped performance monitor history window in seconds. This changes app monitor state and requires user approval.',
        properties: {
          'seconds': _int('History window in seconds.', minimum: 30),
        },
        required: const ['seconds'],
        handler: (arguments) =>
            _monitorSetHistoryWindow(arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_get_health',
        description:
            'Return current performance monitor health snapshots for one or more server connection ids.',
        properties: {
          'connectionIds': _stringArray(
            'Optional subset of server connection ids. Omit to return all monitor health snapshots.',
          ),
        },
        handler: _monitorGetHealth,
      ),
      AiTool(
        name: 'monitor_get_samples',
        description:
            'Return recent performance monitor samples for one server connection id.',
        properties: {
          'connectionId': _string('Server connection id.'),
          'visibleOnly': _bool(
            'Optional. Default true. When true, return only samples inside the current history window.',
          ),
          'limit': _int(
            'Optional maximum number of newest samples to return. Defaults to 100.',
            minimum: 1,
            maximum: 500,
            defaultValue: 100,
          ),
        },
        required: const ['connectionId'],
        handler: _monitorGetSamples,
      ),
      AiTool(
        name: 'monitor_get_alerts',
        description:
            'Return recent performance monitor alerts across all monitored servers.',
        properties: {
          'limit': _int(
            'Optional maximum number of newest alerts to return. Defaults to 50.',
            minimum: 1,
            maximum: 200,
            defaultValue: 50,
          ),
        },
        handler: _monitorGetAlerts,
      ),
      AiTool(
        name: 'monitor_get_ports',
        description:
            'Return current listening ports and owning processes for one server using the existing performance monitor diagnostics path.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _monitorGetPorts,
      ),
      AiTool(
        name: 'monitor_get_applications',
        description:
            'Return current top applications or processes for one server using the existing performance monitor diagnostics path.',
        properties: {
          'connectionId': _string('Server connection id.'),
        },
        required: const ['connectionId'],
        handler: _monitorGetApplications,
      ),
    ];
  }
}
