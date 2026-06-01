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
}
