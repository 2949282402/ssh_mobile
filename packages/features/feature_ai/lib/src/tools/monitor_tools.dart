part of 'ai_tool_service.dart';

class MonitorToolsProvider implements AiToolProvider {
  final PerformanceMonitorToolAdapter performanceMonitorToolService;
  final StorageService storageService;

  const MonitorToolsProvider({
    required this.performanceMonitorToolService,
    required this.storageService,
  });

  @override
  Future<List<AiTool>> getTools(AiToolService service) async {
    return _getMonitorTools(service);
  }

  @override
  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    switch (name) {
      case 'monitor_get_state':
        return _monitorGetState(service, arguments);
      case 'monitor_set_selected_servers':
        return _monitorSetSelectedServers(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'monitor_clear_selection':
        return _monitorClearSelection(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'monitor_start':
        return _monitorStart(service, arguments, approvedWrite: approvedWrite);
      case 'monitor_stop':
        return _monitorStop(service, arguments, approvedWrite: approvedWrite);
      case 'monitor_stop_for_connection':
        return _monitorStopForConnection(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'monitor_set_interval':
        return _monitorSetInterval(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'monitor_set_history_window':
        return _monitorSetHistoryWindow(
          service,
          arguments,
          approvedWrite: approvedWrite,
        );
      case 'monitor_get_health':
        return _monitorGetHealth(service, arguments);
      case 'monitor_get_samples':
        return _monitorGetSamples(service, arguments);
      case 'monitor_get_alerts':
        return _monitorGetAlerts(service, arguments);
      case 'monitor_get_ports':
        return _monitorGetPorts(service, arguments);
      case 'monitor_get_applications':
        return _monitorGetApplications(service, arguments);
      default:
        return null;
    }
  }

  Future<String> _monitorGetState(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(performanceMonitorToolService.getState());
  }

  Future<String> _monitorSetSelectedServers(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor selection requires user approval.',
      });
    }
    final ids = service._stringList(arguments['connectionIds']);
    for (final id in ids) {
      if (storageService.getConnection(id) == null) {
        throw StateError('Unknown connection id: $id');
      }
    }
    return jsonEncode(performanceMonitorToolService.setSelectedServers(ids));
  }

  Future<String> _monitorClearSelection(
    AiToolService service,
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
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Starting performance monitoring requires user approval.',
      });
    }
    final binding = service.activeApprovalExecutionBinding;
    final targets = binding?.connectionTargets ?? const {};
    if (binding?.resourceKind != 'monitor_selection' ||
        targets.isEmpty ||
        performanceMonitorToolService is! BoundPerformanceMonitorToolAdapter) {
      return jsonEncode({
        'error':
            'The approved monitor target set is no longer available. Review it and approve again.',
        'code': 'approval_target_changed',
      });
    }
    return jsonEncode(
      await (performanceMonitorToolService
              as BoundPerformanceMonitorToolAdapter)
          .startWithTargets(targets),
    );
  }

  Future<String> _monitorStop(
    AiToolService service,
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
    AiToolService service,
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
        service._arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _monitorSetInterval(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor sampling settings requires user approval.',
      });
    }
    final seconds = service._argInt(arguments, 'seconds').clamp(2, 300);
    return jsonEncode(
      performanceMonitorToolService.setInterval(Duration(seconds: seconds)),
    );
  }

  Future<String> _monitorSetHistoryWindow(
    AiToolService service,
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Changing monitor history settings requires user approval.',
      });
    }
    final seconds = service._argInt(arguments, 'seconds').clamp(30, 600);
    return jsonEncode(
      performanceMonitorToolService.setHistoryWindow(
        Duration(seconds: seconds),
      ),
    );
  }

  Future<String> _monitorGetHealth(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(
      performanceMonitorToolService.getHealth(
        connectionIds: service._optionalStringList(arguments, 'connectionIds'),
      ),
    );
  }

  Future<String> _monitorGetSamples(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(
      performanceMonitorToolService.getSamples(
        service._arg(arguments, 'connectionId'),
        visibleOnly: service._optionalBool(arguments, 'visibleOnly') ?? true,
        limit: service._optionalInt(arguments, 'limit') ?? 100,
      ),
    );
  }

  Future<String> _monitorGetAlerts(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(
      performanceMonitorToolService.getAlerts(
        limit: service._optionalInt(arguments, 'limit') ?? 50,
      ),
    );
  }

  Future<String> _monitorGetPorts(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(
      await performanceMonitorToolService.getPorts(
        service._arg(arguments, 'connectionId'),
      ),
    );
  }

  Future<String> _monitorGetApplications(
    AiToolService service,
    Map<String, dynamic> arguments,
  ) async {
    return jsonEncode(
      await performanceMonitorToolService.getApplications(
        service._arg(arguments, 'connectionId'),
      ),
    );
  }

  List<AiTool> _getMonitorTools(AiToolService service) {
    return [
      AiTool(
        name: 'monitor_get_state',
        description:
            'Return the app-scoped performance monitor state for selected servers, running status, effective intervals, alerts, and health snapshots.',
        properties: const {},
        handler: (args) => _monitorGetState(service, args),
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
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) => _monitorSetSelectedServers(
          service,
          arguments,
          approvedWrite: false,
        ),
      ),
      AiTool(
        name: 'monitor_clear_selection',
        description:
            'Clear the performance monitor selected server set. This changes app monitor state and requires user approval.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _monitorClearSelection(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_start',
        description:
            'Start the app-scoped performance monitor for the currently selected servers. This changes app monitor state and requires user approval.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _monitorStart(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_stop',
        description:
            'Stop the app-scoped performance monitor. This changes app monitor state and requires user approval.',
        properties: const {},
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _monitorStop(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_stop_for_connection',
        description:
            'Stop the app-scoped performance monitor for one connection id. This changes app monitor state and requires user approval.',
        properties: {'connectionId': _string('Server connection id.')},
        required: const ['connectionId'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _monitorStopForConnection(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_set_interval',
        description:
            'Set the app-scoped performance monitor sampling interval in seconds. This changes app monitor state and requires user approval.',
        properties: {
          'seconds': _int('Sampling interval in seconds.', minimum: 2),
        },
        required: const ['seconds'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _monitorSetInterval(service, arguments, approvedWrite: false),
      ),
      AiTool(
        name: 'monitor_set_history_window',
        description:
            'Set the app-scoped performance monitor history window in seconds. This changes app monitor state and requires user approval.',
        properties: {
          'seconds': _int('History window in seconds.', minimum: 30),
        },
        required: const ['seconds'],
        executionMode: AiToolExecutionMode.stateChanging,
        handler: (arguments) =>
            _monitorSetHistoryWindow(service, arguments, approvedWrite: false),
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
        handler: (args) => _monitorGetHealth(service, args),
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
        handler: (args) => _monitorGetSamples(service, args),
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
        handler: (args) => _monitorGetAlerts(service, args),
      ),
      AiTool(
        name: 'monitor_get_ports',
        description:
            'Return current listening ports and owning processes for one server using the existing performance monitor diagnostics path.',
        properties: {'connectionId': _string('Server connection id.')},
        required: const ['connectionId'],
        handler: (args) => _monitorGetPorts(service, args),
      ),
      AiTool(
        name: 'monitor_get_applications',
        description:
            'Return current top applications or processes for one server using the existing performance monitor diagnostics path.',
        properties: {'connectionId': _string('Server connection id.')},
        required: const ['connectionId'],
        handler: (args) => _monitorGetApplications(service, args),
      ),
    ];
  }
}
